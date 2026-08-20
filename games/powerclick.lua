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
	-- On: verified. HatchEgg takes the egg's INDEX (a name answers "Bad egg") and
	-- it is not position-gated at all - hatched from 145 studs away, wins 566 -> 516.
	eggs = true,
	eggReserve = 3,        -- only hatch while wins >= cost * this, so eggs never
	                       -- starve the upgrades that make the runs deeper
	equipBest = true,      -- press EquipBest after every hatch and on the timer
	merge = true,          -- three identical pets -> one of the next variant
	freebies = true,       -- banked wheel spins, daily reward, potions
	trainSeconds = 45,     -- how long to train before going back into the cave
	caveSeconds = 90,      -- hard cap on one cave run
	stallSeconds = 8,      -- no wall progress for this long -> cash the run in
	hitGap = 0.03,         -- seconds between wall hits
	rebirthUntil = 0,      -- 0 = no limit
	spendEvery = 10,       -- seconds between spending passes
	swordReach = 1.25,     -- reserve the next rung only once it is nearly affordable
	cheapShare = 0.05,     -- anything under this share of the balance ignores the
	                       -- reserve entirely, so cheap compounding rows never stall
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
	world = 1, pets = 0, needLevel = nil, multiplier = 1, reserve = 0,
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

--------------------------------------------------------------------------------
-- worlds
--
-- Nothing here may be hardcoded to world 1. The game repeats the same layout four
-- times and only the suffix changes: WallConfig / WallConfig2..4, the cursor
-- attribute CaveWall / CaveWall2..4, and the cave and shop folders which live
-- under Workspace.World2..4 instead of at the top. The world number itself comes
-- from WorldTeleportRemote, and its w2Available/w3Available flags are server
-- availability, NOT permission - the gate is rebirths >= 45 / 160 / 265.
--------------------------------------------------------------------------------

local worldCache, worldCachedAt = 1, 0

local function currentWorld()
	if os.clock() - worldCachedAt < 15 then return worldCache end
	local fn = remote("WorldTeleportRemote")
	if fn then
		local ok, state = pcall(function() return fn:InvokeServer("GetState") end)
		if ok and state and tonumber(state.world) then
			worldCache = tonumber(state.world)
		end
	end
	worldCachedAt = os.clock()
	return worldCache
end

local function suffix(world)
	return world > 1 and tostring(world) or ""
end

local function wallConfigFor(world)
	local module = ReplicatedStorage:FindFirstChild("WallConfig" .. suffix(world))
	if not module then return nil end
	local ok, cfg = pcall(require, module)
	return ok and cfg or nil
end

local function wallCursorName(world)
	return "CaveWall" .. suffix(world)
end

-- The cave and the shops sit at the top level in world 1 and inside
-- Workspace.World<n> everywhere else. Search both, in that order.
local function worldFolder(world, name)
	if world > 1 then
		local root = workspace:FindFirstChild("World" .. world)
		local inner = root and root:FindFirstChild(name, true)
		if inner then return inner end
	end
	return workspace:FindFirstChild(name)
end

local wallConfig = wallConfigFor(1)

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
	local world = currentWorld()
	if world ~= STATE.world then
		STATE.world = world
		wallConfig = wallConfigFor(world) or wallConfig
		STATE.deepest = 1
		note("world " .. world)
	end
	STATE.wall = plr:GetAttribute(wallCursorName(world)) or 1
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
	local world = STATE.world or 1
	-- world 1 keeps its pads in PrototypeTrainingArea; later worlds carry theirs
	-- inside Workspace.World<n>, so search the world root when there is one
	local area = worldFolder(world, "PrototypeTrainingArea")
		or (world > 1 and workspace:FindFirstChild("World" .. world))
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
	local world = STATE.world or 1
	local root = worldFolder(world, "CaveWorld")
		or (world > 1 and workspace:FindFirstChild("World" .. world))
		or workspace
	for _, d in ipairs(root:GetDescendants()) do
		-- Is2x marks the Robux twin. Filter on the attribute, never on the name.
		if d:IsA("BasePart") and d.Name:find("CavePad") and d:GetAttribute("Is2x") == false then
			-- later worlds number their pads the same way, so key on the zone
			local zone = tonumber(d:GetAttribute("Zone")) or tonumber(d.Name:match("Z(%d+)"))
			if zone then pads["CavePad_Z" .. zone] = d end
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
			if gained > 0 or (plr:GetAttribute(wallCursorName(STATE.world or 1)) or 1) == 1 then
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

	local cursorName = wallCursorName(STATE.world or 1)
	local unpin = pin(function()
		local n = plr:GetAttribute(cursorName) or 1
		local ok, z = pcall(wallConfig.wallZ, n)
		if not ok then return nil end
		return Vector3.new(wallConfig.X, wallConfig.FLOOR_TOP + 4, z - 6)
	end)
	task.wait(1)

	local t0 = os.clock()
	local lastWall = plr:GetAttribute(cursorName) or 1
	local lastMove = os.clock()
	local breakTimes = {}

	-- the patience for the CURRENT wall, from what the recent ones actually cost
	local function stallLimit()
		if #breakTimes == 0 then return CONFIG.stallSeconds end
		local sum = 0
		for _, t in ipairs(breakTimes) do sum = sum + t end
		local avg = sum / #breakTimes
		return math.clamp(math.max(CONFIG.stallSeconds, avg * 4), CONFIG.stallSeconds, 60)
	end

	while CONFIG.auto and CONFIG.cave and GEN == _G.__POWERCLICK do
		pcall(function() ev:FireServer() end)
		task.wait(CONFIG.hitGap)

		local now = plr:GetAttribute(cursorName) or 1
		if now ~= lastWall then
			-- remember how long the last few walls took: deep walls legitimately
			-- take longer, and a fixed stall limit would cut the run short exactly
			-- where it is worth the most
			local took = os.clock() - lastMove
			table.insert(breakTimes, took)
			if #breakTimes > 6 then table.remove(breakTimes, 1) end
			lastWall, lastMove = now, os.clock()
			if now > STATE.deepest then STATE.deepest = now end
			STATE.wall = now
			note("cave wall " .. now .. "   hp " ..
				short(select(2, pcall(wallConfig.wallHp, now)) or 0))
		end

		-- The run ends on a STALL, never on a fixed depth: the pad resets the
		-- cursor, so quitting while walls are still falling throws away the part
		-- of the run that is worth the most.
		if os.clock() - lastMove > stallLimit() then
			note("wall " .. lastWall .. " will not fall after " ..
				math.floor(stallLimit()) .. "s - cashing in")
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

-- Loot Evo's trap was that a sword is held by the BALANCE and spending takes it
-- back. Tested here and it does NOT apply: the balance was spent from 354 down to
-- 37 while the equipped sword cost 100, and the 30-power sword stayed; standing on
-- its stand again with 37 wins did not take it either. Swords are bought once.
--
-- The floor below is therefore insurance, not a proven rule - it costs nothing
-- because the target reserve is almost always the larger of the two. What IS
-- proven is the target: saving for the next sword instead of dribbling the balance
-- away on cheap upgrade rows. Reserves are never summed, the largest wins.
-- The three that compound: damage decides how deep the walls fall, clickPower how
-- fast strength arrives, and wins multiplies every single cashout. attackSpeed is
-- next because the hit rate is what turns strength into depth.
--
-- Rank, not order. The first version stopped after ONE purchase and always ran
-- damage first, so damage sat at 1.60x for 200 wins while the WINS upgrade was
-- still 1.00x and cost 1 - the cheapest compounding buy in the game, skipped every
-- pass. Now every affordable row is bought, cheapest of the wanted ones first.
-- walkSpeed is deliberately absent: the script pins and teleports, so movement
-- speed buys nothing at all, and it was quietly eating the balance at cost 1.
local UPGRADE_RANK = { damage = 1, clickPower = 1, wins = 1, attackSpeed = 2 }

-- Loot Evo's trap was that a sword is held by the BALANCE and spending takes it
-- back. Tested here and it does NOT apply: the balance was spent from 354 down to
-- 37 while the equipped sword cost 100, and the 30-power sword stayed; standing on
-- its stand again with 37 wins did not take it either. Swords are bought once.
--
-- The floor below is therefore insurance, not a proven rule - it costs nothing
-- because the target reserve is almost always the larger of the two. What IS
-- proven is the target: saving for the next sword instead of dribbling the balance
-- away on cheap upgrade rows. Reserves are never summed, the largest wins.
local function swordFloor()
	local folder = worldFolder(STATE.world or 1, "ShopStands")
	if not folder then return 0 end
	local floor = 0
	for _, m in ipairs(folder:GetChildren()) do
		local cost = tonumber(m:GetAttribute("SwordCost"))
		local power = tonumber(m:GetAttribute("SwordPower"))
		-- the equipped sword is the most expensive one the balance still covers
		if cost and power and not m:GetAttribute("GamepassId")
			and power <= (STATE.sword or 1) and cost > floor then
			floor = cost
		end
	end
	return floor
end

-- Swords are first priority now, so the next rung is fenced off before anything
-- else may spend - but only once it is actually within reach. Reserving a rung
-- that is twenty times the balance would freeze every other purchase forever,
-- which is the starvation pattern this project has hit six times before.
local function swordTarget(wins)
	local folder = worldFolder(STATE.world or 1, "ShopStands")
	if not folder then return 0 end
	local cheapest
	for _, m in ipairs(folder:GetChildren()) do
		local cost = tonumber(m:GetAttribute("SwordCost"))
		local power = tonumber(m:GetAttribute("SwordPower"))
		if cost and cost > 0 and power and not m:GetAttribute("GamepassId")
			and power > (STATE.sword or 1) then
			if not cheapest or cost < cheapest then cheapest = cost end
		end
	end
	if not cheapest then return 0 end
	-- Engaging at 3x looked prudent and was the bug the user caught: with 28,675
	-- wins and a 40,000 rung the reserve swallowed the entire balance while the
	-- cheapest upgrade cost 85, so the bot farmed for minutes and bought nothing.
	-- The reserve only makes sense once the rung is nearly in hand.
	return (cheapest <= wins * CONFIG.swordReach) and cheapest or 0
end

-- One guard, asked by every spender. Not the sum: the largest.
local function spendable(wins)
	wins = wins or value("Wins", 0)
	-- swordFloor is NOT in here. Keeping the equipped sword's price fenced off
	-- looked like cheap insurance and instead froze every purchase in the game:
	-- the equipped sword cost 8,000 against a 1,337 balance, so nothing was ever
	-- spendable. Swords were measured to be permanent, so only the next rung is
	-- reserved - that is the one purchase the balance actually has to reach.
	local reserve = swordTarget(wins)
	STATE.reserve = reserve
	return math.max(0, wins - reserve)
end

-- Trivially cheap steps bypass the guard. Blocking an 85-win upgrade that pays for
-- itself in one cave run, in order to save for a 40,000 sword, is backwards.
local function canSpend(cost, wins)
	wins = wins or value("Wins", 0)
	if cost <= wins * CONFIG.cheapShare then return cost <= wins end
	return cost <= spendable(wins)
end

-- The three that compound: damage decides how deep the walls fall, clickPower how
-- fast strength arrives, and wins multiplies every single cashout. attackSpeed is
-- next because the hit rate is what turns strength into depth.
--
-- Rank, not order. The first version stopped after ONE purchase and always ran
-- damage first, so damage sat at 1.60x for 200 wins while the WINS upgrade was
-- still 1.00x and cost 1 - the cheapest compounding buy in the game, skipped every
-- pass. Now every affordable row is bought, cheapest of the wanted ones first.
-- walkSpeed is deliberately absent: the script pins and teleports, so movement
-- speed buys nothing at all, and it was quietly eating the balance at cost 1.
local UPGRADE_RANK = { damage = 1, clickPower = 1, wins = 1, attackSpeed = 2 }

local function buyUpgrades()
	local fn = remote("UpgradeFunction")
	if not fn then return false end
	local bought = false

	for _ = 1, 12 do                       -- bounded: prices climb, this ends on its own
		local ok, reply = pcall(function() return fn:InvokeServer("GetState") end)
		local state = ok and (reply and (reply.state or reply)) or nil
		if not (state and state.upgrades) then return bought end
		local wins = tonumber(state.wins) or value("Wins", 0)

		local budget = spendable(wins)

		local pick
		for _, row in ipairs(state.upgrades) do
			local rank = UPGRADE_RANK[row.id]
			local cost = tonumber(row.cost)
			-- The reply carries robuxPrice on every row; "Buy" plus the id is the
			-- wins path, so nothing here can reach a purchase prompt.
			if rank and not row.maxed and cost and canSpend(cost, wins) then
				if not pick or rank < pick.rank or (rank == pick.rank and cost < pick.cost) then
					pick = { id = row.id, cost = cost, rank = rank, name = row.name, level = row.level }
				end
			end
		end
		if not pick then return bought end

		local done, out = pcall(function() return fn:InvokeServer("Buy", pick.id) end)
		if not (done and out and out.success) then return bought end
		bought = true
		note("upgrade " .. (pick.name or pick.id) .. " lvl " ..
			tostring((pick.level or 0) + 1) .. " for " .. short(pick.cost))
		task.wait(0.2)
	end
	return bought
end

local function swordStands()
	local stands = {}
	local folder = worldFolder(STATE.world or 1, "ShopStands")
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

-- The ladder is climbed RUNG BY RUNG. You cannot walk onto the 4,000 stand while
-- holding the 400 one even with the money in hand - the stands in between have to
-- be bought first, so the real price of a distant sword is the SUM of every rung
-- up to it. That is what makes a naive "best affordable" jump quietly stall.
local function swordLadder()
	local ladder = {}
	for _, stand in ipairs(swordStands()) do
		-- a gamepass stand reports SwordCost 0, which would otherwise read as free
		if not stand.pass and stand.cost and stand.cost > 0 then
			ladder[#ladder + 1] = stand
		end
	end
	table.sort(ladder, function(a, b) return a.power < b.power end)
	return ladder
end

local function nextRung()
	for _, stand in ipairs(swordLadder()) do
		if stand.power > (STATE.sword or 1) then return stand end
	end
	return nil
end

-- What it costs to get from here to that rung, every step included.
local function costToReach(target)
	local total = 0
	for _, stand in ipairs(swordLadder()) do
		if stand.power > (STATE.sword or 1) and stand.power <= target.power then
			total = total + stand.cost
		end
	end
	return total
end

local function standOn(stand)
	local ped = stand.model:FindFirstChild("ShopPedestal", true)
	if not ped then return false end
	local pos = ped:IsA("BasePart") and ped.Position or ped:GetPivot().Position
	local before = STATE.sword
	local unpin = pin(function() return pos + Vector3.new(0, 3, 0) end)
	task.wait(3.5)                        -- the stand hands it over while you stand there
	unpin()
	refresh()
	return STATE.sword > before
end

-- Purely for the footer line: what the next rung is and what the whole climb to
-- the best rung in sight really costs, rungs in between included.
local function swordPlan()
	local rung = nextRung()
	if not rung then return "sword maxed" end
	local best = rung
	for _, stand in ipairs(swordLadder()) do
		if stand.power > (STATE.sword or 1) and costToReach(stand) <= math.max(1, STATE.wins) then
			best = stand
		end
	end
	if best ~= rung then
		return string.format("next %s %s   reachable up to %s (%s all rungs)",
			rung.model.Name, short(rung.cost), best.model.Name, short(costToReach(best)))
	end
	return string.format("next %s for %s", rung.model.Name, short(rung.cost))
end

local function buyBestSword()
	local climbed = false
	for _ = 1, 6 do                        -- a few rungs per pass, never a jump
		local rung = nextRung()
		if not rung then break end
		refresh()
		if rung.cost > STATE.wins then break end
		if not standOn(rung) then break end
		climbed = true
		STATE.swordName = rung.model.Name
		note("sword " .. rung.model.Name .. "   power " .. short(STATE.sword) ..
			"   for " .. short(rung.cost))
	end
	return climbed
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

--------------------------------------------------------------------------------
-- pets
--------------------------------------------------------------------------------

-- HatchEgg wants the egg's INDEX in the state list, not its name: "Basic Egg"
-- answers "Bad egg" while 1 hatches it. And it is NOT position-gated - hatched
-- from 145 studs away. The `worldPos` the server hands out is wrong anyway (it
-- points left of spawn while the machines stand on the right), so walking to it
-- would be both pointless and misleading.
local function petState()
	local fn = remote("PetFunction")
	if not fn then return nil end
	local ok, state = pcall(function() return fn:InvokeServer("GetState") end)
	return ok and state or nil
end

local function equipBestPets()
	local fn = remote("PetFunction")
	if not fn then return false end
	return (pcall(function() return fn:InvokeServer("EquipBest") end))
end

local function hatchBestEgg()
	local fn = remote("PetFunction")
	local state = petState()
	if not (fn and state and state.eggs) then return false end

	local wins = value("Wins", 0)
	local pick, pickIndex
	for i, egg in ipairs(state.eggs) do
		local cost = tonumber(egg.cost)
		-- The Galaxy Egg reports cost 0 because it is paid in Robux; without the
		-- flag check a "cheapest first" sort puts it at the very top.
		-- the shared guard first, then the user's stricter rule on top: never buy a
		-- non-weapon until the balance is a multiple of its price
		if not egg.robux and cost and cost > 0
			and canSpend(cost, wins) and cost * CONFIG.eggReserve <= wins then
			if not pick or cost > pick.cost then pick, pickIndex = { cost = cost, name = egg.name }, i end
		end
	end
	if not pick then return false end

	local before = value("Wins", 0)
	local ok, reply = pcall(function() return fn:InvokeServer("HatchEgg", pickIndex, 1) end)
	task.wait(1)
	refresh()
	if ok and reply and reply.success and value("Wins", 0) < before then
		local hatched = reply.hatched and reply.hatched[1]
		STATE.pets = tonumber(reply.ownedCount) or STATE.pets
		note("hatched " .. tostring(hatched and hatched.name or "?") ..
			" x" .. tostring(hatched and hatched.strMult or "?") .. " from " .. pick.name)
		equipBestPets()
		return true
	end
	return false
end

-- Merging takes three of the SAME pet and the same variant and returns one of the
-- next variant up (Normal -> Golden -> Rainbow), which the game advertises as
-- twice as good. Two actions exist on PetFunction: "StartMerge" and "ClaimMerge";
-- everything else answers "Unknown action". The merge then runs on a timer, and
-- the `MergeReady` attribute is what says it is done - FusionClient's skip button
-- is a gamepass, so the timer is simply waited out.
local function mergePets()
	local fn = remote("PetFunction")
	local state = petState()
	if not (fn and state and state.owned) then return false end

	if plr:GetAttribute("MergeReady") then
		local ok, reply = pcall(function() return fn:InvokeServer("ClaimMerge") end)
		if ok and reply and not reply.err then
			note("merge collected")
			equipBestPets()
			return true
		end
	end

	-- group by name and variant; three of a kind is the requirement
	local groups = {}
	for index, pet in ipairs(state.owned) do
		if not pet.locked then
			local key = tostring(pet.name) .. "|" .. tostring(pet.variant)
			groups[key] = groups[key] or {}
			table.insert(groups[key], index)
		end
	end
	for _, indices in pairs(groups) do
		if #indices >= 3 then
			local ok, reply = pcall(function()
				return fn:InvokeServer("StartMerge", indices[1], indices[2], indices[3])
			end)
			if ok and reply and not reply.err then
				note("merging 3 pets")
				return true
			end
			-- a shape that is refused is worth saying out loud rather than retrying
			if ok and reply and reply.err then note("merge refused: " .. tostring(reply.err)) end
			return false
		end
	end
	return false
end

--------------------------------------------------------------------------------
-- free stuff - worth more than the farm at this stage
--------------------------------------------------------------------------------

-- The wheel banks its spins and pays 40% +250, 30% +1K, 5% +50K Wins and 3.5% a
-- free rebirth. A whole cave run at zone 6 pays 100, so this outruns the farm by
-- an order of magnitude. The reply is the animation result and the balance only
-- moves a second or two later - confirm on the balance, never on the reply.
local function claimSpins()
	local fn = remote("SpinWheelFunction")
	if not fn then return false end
	local ok, state = pcall(function() return fn:InvokeServer("GetState") end)
	if not (ok and state and (tonumber(state.spins) or 0) > 0) then return false end

	local before = value("Wins", 0)
	local spun = 0
	for _ = 1, math.min(tonumber(state.spins) or 0, 10) do
		local fired, reply = pcall(function() return fn:InvokeServer("Spin") end)
		if not (fired and reply and reply.ok) then break end
		spun = spun + 1
		note("spin: " .. tostring(reply.label))
		task.wait(1.5)
	end
	task.wait(2)                          -- the credit lands late
	refresh()
	if spun > 0 then
		note(spun .. " spins   +" .. short(value("Wins", 0) - before) .. " wins")
		return true
	end
	return false
end

local function claimDaily()
	local fn = remote("DailyRewardFunction")
	if not fn then return false end
	local ok, state = pcall(function() return fn:InvokeServer("GetState") end)
	if not (ok and state and state.canClaim) then return false end
	local done, reply = pcall(function() return fn:InvokeServer("Claim") end)
	if done and reply and reply.success then
		note("daily day " .. tostring(reply.dayIdx) .. ": " ..
			tostring(reply.reward and (reply.reward.title or ""):gsub("\n", " ")))
		return true
	end
	return false
end

-- PotionFunction takes "Use" plus the kind; every other verb answers "Unknown op".
-- Verified: PotionInv_power 1 -> 0 and PotionPowerMult 1 -> 2.
local function usePotions()
	local fn = remote("PotionFunction")
	if not fn then return false end
	local used = false
	for _, kind in ipairs({ "power", "wins", "luck" }) do
		local have = tonumber(plr:GetAttribute("PotionInv_" .. kind)) or 0
		local active = value(kind == "power" and "PotionPowerMult"
			or kind == "wins" and "PotionWinsMult" or "PotionLuckMult", 1)
		-- never stack a fresh potion on top of a running one
		if have > 0 and active <= 1 then
			pcall(function() fn:InvokeServer("Use", kind) end)
			task.wait(0.4)
			used = true
			note("potion " .. kind .. " x" .. tostring(
				value(kind == "power" and "PotionPowerMult" or "PotionWinsMult", 1)))
		end
	end
	return used
end

-- Split on purpose. Everything here is a plain remote call that works from
-- anywhere, so it must NOT wait for the cave run to end - a deep run takes over a
-- minute and the wins upgrade compounds on every cashout, so paying for it late
-- costs real income. Only the two that need the body (swords) or that would throw
-- away a run in progress (rebirth) stay in the serial cycle.
local function freePass()
	withUI("free", function()
		refresh()
		-- checked every pass now, not once per cycle: CanRebirth sat true for
		-- minutes while the run was still in the cave. Never during a run though,
		-- because a rebirth resets the strength that run is built on.
		if CONFIG.rebirth and STATE.phase ~= "cave" then doRebirth() end
		if CONFIG.freebies then
			claimSpins()
			claimDaily()
			usePotions()
		end
		if CONFIG.upgrades then buyUpgrades() end
		if CONFIG.eggs then hatchBestEgg() end
		if CONFIG.merge then mergePets() end
		if CONFIG.equipBest then equipBestPets() end
	end)
end

local function spendPass()
	withUI("spend", function()
		refresh()
		if CONFIG.rebirth then doRebirth() end
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

-- the position-free half, on its own timer, so a long cave run never delays it
task.spawn(function()
	while GEN == _G.__POWERCLICK do
		if CONFIG.auto then freePass() end
		task.wait(CONFIG.spendEvery)
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

local pets = page:Card("PETS & FREE STUFF", 1)
pets:Toggle("Hatch eggs", CONFIG.eggs, function(v) CONFIG.eggs = v end,
	"best affordable egg by index, Robux eggs filtered by their own flag", UI.theme.warn)
pets:Stepper("Egg reserve", function() return "x" .. CONFIG.eggReserve end, function(dir)
	CONFIG.eggReserve = math.clamp(CONFIG.eggReserve + dir, 1, 10)
end, "only hatch while wins are this many times the egg price")
pets:Toggle("Equip best", CONFIG.equipBest, function(v) CONFIG.equipBest = v end,
	"presses the pet window's Equip Best after every hatch")
pets:Toggle("Merge pets", CONFIG.merge, function(v) CONFIG.merge = v end,
	"three identical pets -> one of the next variant, 2x better")
pets:Toggle("Free rewards", CONFIG.freebies, function(v) CONFIG.freebies = v end,
	"banked wheel spins, daily reward and potions", UI.theme.good)

local out = page:Card("STATUS", 0):Readout(11, function(text)
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
			"  world    " .. tostring(STATE.world) .. "   pets " .. tostring(STATE.pets),
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

-- Der Home-Tab: das GitHub-Commit-Log als Changelog plus der aktuelle Lauf.
-- Zuletzt deklariert, aber das Template schiebt ihn an den Anfang der Leiste -
-- er ist immer das erste Icon und die Seite, auf der das Panel aufgeht.
pcall(function() win:Home() end)

win:Refresh()

--------------------------------------------------------------------------------

_G.__POWERCLICK_DBG = {
	CONFIG = CONFIG, STATE = STATE,
	refresh = refresh, short = short, pin = pin,
	trainingPads = trainingPads, bestPad = bestPad, trainPhase = trainPhase,
	cashPads = cashPads, cashOut = cashOut, cavePhase = cavePhase,
	buyUpgrades = buyUpgrades, swordStands = swordStands, buyBestSword = buyBestSword,
	doRebirth = doRebirth, spendPass = spendPass, freePass = freePass,
	swordFloor = swordFloor, swordTarget = swordTarget, spendable = spendable,
	swordLadder = swordLadder, nextRung = nextRung, costToReach = costToReach,
	swordPlan = swordPlan,
	petState = petState, hatchBestEgg = hatchBestEgg, equipBestPets = equipBestPets,
	mergePets = mergePets, claimSpins = claimSpins, claimDaily = claimDaily,
	usePotions = usePotions, currentWorld = currentWorld, wallConfigFor = wallConfigFor,
	wallConfig = wallConfig,
}

print("[powerclick] gen " .. GEN .. " ready - RightShift for the panel")
