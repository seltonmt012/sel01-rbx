--[[ heroevo.lua - "🦸 +1 Superhero Evolution" (place 97824450589417)

  The loop the game actually runs:

      stand in a TRAINING ZONE  -> +Power every 0.5s  (Gain x ZoneMulti x TotalMulti)
      Power IS the damage       -> walk a chain of STAGES, the server kills the wave
      the WIN PAD of the deepest cleared stage pays that stage's WinAmount
      Wins                      -> morphs (Gain), eggs/pets (multiplier)
      Rebirth                   -> a flat multiplier and the next training zones
      three worlds, ALL IN ONE PLACE (Map / MapTest / Map3), 45 stages, 27 zones

  Everything below was measured against the server through the bridge before it
  was written down. The five findings that shape this file:

  * A STAGE ONLY SPAWNS ITS WAVE WHEN THE BODY CROSSES ITS GATE. Standing inside
    the fight area does nothing at all - 7s in the middle of stage 1 produced zero
    spawns - and a teleport that lands inside without crossing the boundary is the
    same. Every entry here therefore CREEPS across the gate plane in 3-stud steps,
    from outside to inside, which is what a walking player does.

  * A CLEARED STAGE STAYS CLEARED AND STOPS SPAWNING. After the wave dies the
    barrier drops for good; re-crossing the gate produces nothing. Only the win
    pad resets it - it fires BarriersReset and teleports the body to the lobby.
    So a run is: cross gate 1, clear, cross gate 2, clear, ... claim the pad of
    the DEEPEST stage reached. Claiming a shallow pad throws the whole run away.
    (On stage 1 a naive pin looked like an endless farm - 45 spawns in 8s - only
    because the pad's own return teleport plus the pin re-crossed gate 1 over and
    over. That trick does not survive to stage 2.)

  * THE CHAIN IS STRICTLY SEQUENTIAL. Stage N+1 will not spawn while stage N is
    unfinished, whatever the body's position, because its barrier is still up.

  * POWER HAS ONE ENGINE AND NO EXPLOIT. The server ticks it every 0.5s while the
    body is inside a training zone. `PlayerClick:FireServer()` is the same tick on
    the same 0.5s cooldown (10 calls over 3s credited exactly 6 x Gain), the two do
    NOT stack (30 vs 33 power over the same 8s), `RequestAttack` credits nothing,
    and `RequestTrain` - despite the name - credits nothing at all. So the levers
    are the morph's Gain, the zone's Multiplier and the rebirth count, and there is
    no click loop worth writing.

  * THE GAME SHIPS ITS OWN FRONTIER FORMULA. `Shared.Utils.StagePower
    .getRecommendedPower(world, stage)` is exactly totalHP/10, and
    `computeStageTotalHealth` gives the HP a wave really has. Measured against it:
    stage 3 (5,000 HP, recommended 500) cleared in 8.9s at 766 power, so the server
    deals about 0.7 x Power per second, and a stage costs a flat ~5.5s of creeping,
    spawning and waiting for the enemies to walk in whatever its size. Those two
    constants are what the target picker below is built on, which is why no stage
    table is hardcoded anywhere.

  Never spends Robux: `Pad.Paid` beside every win pad (the x2 twin), every training
  zone carrying a `GamepassId` (x3 / x10 / x150 / x250), every egg and crate whose
  `Currency` is "Robux" - they have no `Cost` at all and would sort to the front of
  a cheapest-first list - `DevProductIds` (44 of them, including SKIP_REBIRTH and
  the PERMA multipliers), `GamepassIds`, the limited-stock store and the boss
  event's revive and skip products.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local plr = Players.LocalPlayer

local GEN = (_G.__HEROEVO or 0) + 1
_G.__HEROEVO = GEN

--------------------------------------------------------------------------------
-- config
--------------------------------------------------------------------------------

local CONFIG = {
	auto = false,

	stages = true,          -- walk the stage chain and claim the deepest pad
	train = true,           -- stand in the best training zone between runs
	trainSecs = 15,         -- seconds of training after every run
	stageMode = "Auto",     -- Auto | Manual
	stageTarget = 1,        -- manual target, world-local (1..15)
	maxRunSecs = 180,       -- a run longer than this is never worth its wins
	stageTimeout = 25,      -- give up on a single stage after this and stop the run

	morphs = true,          -- climb the morph ladder; Gain is the whole engine
	eggs = true,            -- wins-priced eggs only; the pet multiplier is the best
	                        -- wins-per-multiplier in the game at every tier measured
	pets = true,            -- EquipBestPets / EquipBestArtifacts
	rebirth = true,         -- gate is the LEVEL, not the wins - see rebirthPass
	rebuildGap = 3,         -- stages below the frontier at which a run is skipped
	worlds = true,          -- move on once the previous world is cleared
	freebies = true,        -- playtime, offline earnings, group reward

	winsKeep = 0,           -- wins never spent
}

local STATE = {
	phase = "idle",
	note = "",
	power = 0, wins = 0, level = 0, rebirths = 0, xp = 0,
	world = 1, target = 1, deepest = 0, frontier = 0,
	item = "-", gain = 0, mult = 1, petMult = 1,
	zone = "-", zoneMulti = 0,
	runSecs = 0, lastPay = 0, winRate = 0, powerRate = 0,
	runs = 0, spent = 0, earned = 0,
	busy = false,
}

--------------------------------------------------------------------------------
-- helpers (above their first caller: a local is invisible above its own
-- definition, and inside pcall that surfaces as a quiet note, not a crash)
--------------------------------------------------------------------------------

local function short(n)
	n = tonumber(n) or 0
	local units = {
		{ 1e33, "Dc" }, { 1e30, "No" }, { 1e27, "Oc" }, { 1e24, "Sp" },
		{ 1e21, "Sx" }, { 1e18, "Qi" }, { 1e15, "Qa" }, { 1e12, "T" },
		{ 1e9, "B" }, { 1e6, "M" }, { 1e3, "K" },
	}
	for _, u in ipairs(units) do
		if math.abs(n) >= u[1] then return string.format("%.2f%s", n / u[1], u[2]) end
	end
	return string.format("%.0f", n)
end

local function note(text) STATE.note = text end

local function char()
	local model = plr.Character
	if not model then return nil, nil, nil end
	return model, model:FindFirstChild("HumanoidRootPart"), model:FindFirstChildOfClass("Humanoid")
end

-- AlyaNum crosses the wire as a plain table, so the metatable and its :revert()
-- are gone by the time we see it. The layout is a TOWER HEIGHT, not a mantissa:
-- exponent 0 means the multiplicand IS the number, exponent 1 means 10^m. Nothing
-- in this game reaches exponent 2 - the largest value anywhere is 1.2e25.
local function alya(v)
	if type(v) == "number" then return v end
	if type(v) ~= "table" then return 0 end
	if (v.tetrate or 0) > 0 or (v.pentate or 0) > 0 then return math.huge end
	local m = tonumber(v.multiplicand) or 0
	local e = tonumber(v.exponent) or 0
	local s = tonumber(v.sign) or 1
	local n
	if e <= 0 then n = m
	elseif e == 1 then n = 10 ^ m
	else n = math.huge end
	if s < 0 then n = -n end
	return n
end

--------------------------------------------------------------------------------
-- the game's own modules
--------------------------------------------------------------------------------

local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
local Remotes = Shared:WaitForChild("Remotes", 10)
local Config = Shared:WaitForChild("Config", 10)
local Utils = Shared:WaitForChild("Utils", 10)

pcall(function() setthreadidentity(2) end)

local function tryRequire(inst)
	if not inst then return nil end
	local ok, mod = pcall(require, inst)
	return ok and mod or nil
end

local ItemConfig    = tryRequire(Config:WaitForChild("ItemConfig", 10))
local ZoneConfig    = tryRequire(Config:WaitForChild("ZoneConfig", 10))
local RebirthConfig = tryRequire(Config:WaitForChild("RebirthConfig", 10))
local StageReward   = tryRequire(Config:WaitForChild("StageRewardConfig", 10))
local EggsConfig    = tryRequire(Config:WaitForChild("EggsConfig", 10))
local Playtime      = tryRequire(Config:WaitForChild("PlaytimeRewardsConfig", 10))
local StagePower    = tryRequire(Utils:WaitForChild("StagePower", 10))

local R = {}
for _, name in ipairs({
	"GetData", "RequestRebirth", "RequestWorldChange", "GetPlaytimeRewardsState",
	"ClaimPlaytimeReward", "ClaimOfflineEarnings", "ClaimGroupReward",
	"EquipBestPets", "EquipBestArtifacts", "TryPurchaseEgg", "HatchEgg",
	"UseBoost", "StageUnlocked", "BarriersReset", "PlayVFX",
}) do
	R[name] = Remotes:FindFirstChild(name)
end

--------------------------------------------------------------------------------
-- state
--------------------------------------------------------------------------------

-- CompletedStages in the snapshot is the same list, but it arrives on a round trip
-- and the run has usually moved on by then. StageUnlocked / BarriersReset are the
-- live signal, so the run is tracked here and the snapshot is only a fallback.
local RUN = { cleared = {}, deepest = 0 }
local DATA = {}
local lastData = 0

local function data() return DATA end

local function refresh(force)
	if not force and os.clock() - lastData < 1.5 then return DATA end
	lastData = os.clock()
	if R.GetData then
		local ok, d = pcall(function() return R.GetData:InvokeServer() end)
		if ok and type(d) == "table" then DATA = d end
	end
	local d = DATA
	STATE.power = alya(d.Power)
	STATE.wins = alya(d.Wins)
	STATE.level = tonumber(d.Level) or 0
	STATE.xp = tonumber(d.XP) or 0
	STATE.rebirths = tonumber(d.Rebirths) or 0
	STATE.world = tonumber(d.CurrentWorld) or 1
	STATE.mult = tonumber(d.TotalMultiplier) or 1
	STATE.petMult = tonumber(d.PetMultiplier) or 1
	local item
	if ItemConfig then
		item = ItemConfig[tostring(d.EquippedItem)] or ItemConfig[tonumber(d.EquippedItem) or -1]
	end
	STATE.item = item and item.Name or "-"
	STATE.gain = item and tonumber(item.Gain) or 0
	return d
end

--------------------------------------------------------------------------------
-- the stage table, read from the world rather than hardcoded
--------------------------------------------------------------------------------

local stageCache = {}

local function stageFolder(world, stage)
	local key = world .. ":" .. stage
	local hit = stageCache[key]
	if hit and hit.Parent then return hit end
	for _, v in ipairs(CollectionService:GetTagged("Stage")) do
		if v:GetAttribute("World") == world and v:GetAttribute("Stage") == stage then
			stageCache[key] = v
			return v
		end
	end
	return nil
end

-- Stage numbers are GLOBAL (world 2 is 16..30) while everything the player sees is
-- world-local, so both forms are needed - and neither may be derived by arithmetic
-- on the other. The folder attribute is the authority.
local function stagesOfWorld(world)
	local list = {}
	for _, v in ipairs(CollectionService:GetTagged("Stage")) do
		if v:GetAttribute("World") == world then
			list[#list + 1] = v:GetAttribute("Stage")
		end
	end
	table.sort(list)
	return list
end

local hpCache = {}

local function stageHP(world, stage)
	local key = world .. ":" .. stage
	if hpCache[key] then return hpCache[key] end
	local hp = 0
	if StagePower then
		local ok, v = pcall(StagePower.computeStageTotalHealth, world, stage)
		if ok and v then hp = alya(v) end
	end
	if hp > 0 then hpCache[key] = hp end
	return hp
end

local function stageWins(world, stage)
	local w = StageReward and StageReward[world]
	local e = w and (w[stage] or w[tostring(stage)])
	return e and tonumber(e.WinAmount) or 0
end

-- Measured: the server deals about 0.7 x Power per second to a wave, and a stage
-- costs a flat overhead on top of that whatever its size - the creep across the
-- gate, the spawn, and the enemies walking into range. Timed end to end on stages
-- 1, 2 and 3 with power hundreds of times what they ask for: 5.6s, 5.3s, 6.7s. An
-- earlier 1.7s came from pinning straight onto the spawn point and skipped both
-- the creep and the approach, and using it made the per-stage watchdog too tight.
local DPS_PER_POWER = 0.7
local STAGE_OVERHEAD = 5.5

local function clearSecs(world, stage, power)
	local hp = stageHP(world, stage)
	if hp <= 0 or power <= 0 then return math.huge end
	return hp / (DPS_PER_POWER * power) + STAGE_OVERHEAD
end

local function runLength(world, list, upto, power)
	local t = 0
	for _, s in ipairs(list) do
		if s > upto then break end
		t = t + clearSecs(world, s, power)
	end
	return t
end

-- The best target is the one with the highest wins per second over the WHOLE run,
-- not the deepest reachable. Wins roughly double per stage while the walk only
-- grows linearly, so it is nearly always the deepest that still fits inside
-- maxRunSecs - but it stops being that the moment one stage's HP outruns the power.
local function pickTarget()
	local d = data()
	local world = tonumber(d.CurrentWorld) or 1
	local list = stagesOfWorld(world)
	if #list == 0 then return nil, 0, 0 end
	local power = STATE.power
	local best, bestRate, bestTime = list[1], 0, 0
	for _, s in ipairs(list) do
		-- The picker and the per-stage watchdog have to agree, or the run walks
		-- to a stage the watchdog will never wait out and throws the wins for
		-- every stage below it away. A single stage that cannot fall inside
		-- stageTimeout ends the search here, not at maxRunSecs.
		if clearSecs(world, s, power) > CONFIG.stageTimeout then break end
		local t = runLength(world, list, s, power)
		if t > CONFIG.maxRunSecs then break end
		local rate = stageWins(world, s) / math.max(t, 0.1)
		if rate >= bestRate then best, bestRate, bestTime = s, rate, t end
	end
	return best, bestRate, bestTime
end

--------------------------------------------------------------------------------
-- the body: one pin, one owner
--------------------------------------------------------------------------------

local pinTo = nil

RunService.Heartbeat:Connect(function()
	if GEN ~= _G.__HEROEVO then return end
	if not pinTo then return end
	local _, hrp = char()
	if hrp then hrp.CFrame = CFrame.new(pinTo) end
end)

local function pin(pos) pinTo = pos end
local function unpin() pinTo = nil end

-- A stage's wave spawns on the gate CROSSING, so the body has to arrive from the
-- outside and travel through the plane. The direction is read off the geometry
-- (gate -> spawn) because the three worlds do not share an axis or an origin.
local function enterStage(folder)
	local gate = folder:FindFirstChild("Gate")
	local spawn = folder:FindFirstChild("Spawn")
	if not (gate and gate:IsA("BasePart")) then return false end
	local aim = spawn and spawn.Position or (gate.Position + Vector3.new(0, 0, 10))
	local flat = Vector3.new(aim.X - gate.Position.X, 0, aim.Z - gate.Position.Z)
	if flat.Magnitude < 1 then return false end
	local dir = flat.Unit
	local y = (spawn and spawn.Position.Y or gate.Position.Y) - 2.5
	local base = Vector3.new(gate.Position.X, y, gate.Position.Z)
	for step = -4, 5 do
		pin(base + dir * (step * 3))
		task.wait(0.07)
	end
	return true
end

--------------------------------------------------------------------------------
-- the run
--------------------------------------------------------------------------------

if R.StageUnlocked then
	R.StageUnlocked.OnClientEvent:Connect(function(_, stage)
		if GEN ~= _G.__HEROEVO then return end
		if type(stage) ~= "number" then return end
		RUN.cleared[stage] = true
		if stage > RUN.deepest then RUN.deepest = stage end
		if stage > STATE.frontier then STATE.frontier = stage end
	end)
end

if R.BarriersReset then
	R.BarriersReset.OnClientEvent:Connect(function()
		if GEN ~= _G.__HEROEVO then return end
		RUN.cleared = {}
		RUN.deepest = 0
	end)
end

local lastPayAt = 0

if R.PlayVFX then
	R.PlayVFX.OnClientEvent:Connect(function(kind, _, who, amount)
		if GEN ~= _G.__HEROEVO then return end
		if kind ~= "WinPadTouch" or who ~= plr then return end
		STATE.lastPay = tonumber(amount) or 0
		STATE.earned = STATE.earned + STATE.lastPay
		lastPayAt = os.clock()
	end)
end

-- The pad pays its own stage and then ends the run for every stage, so the one to
-- walk to is always the deepest reached. `Pad.Paid` beside it is the Robux twin -
-- resolve the free one by NAME, never by taking the first model in the folder.
local function claimPad(folder)
	local pad = folder:FindFirstChild("Pad")
	local free = pad and pad:FindFirstChild("Free")
	local part = free and free:FindFirstChild("Pad")
	if not (part and part:IsA("BasePart")) then return false end
	local before = lastPayAt
	pin(part.Position + Vector3.new(0, 4, 0))
	local t = os.clock()
	while os.clock() - t < 3 and lastPayAt == before do task.wait(0.05) end
	task.wait(0.25)
	unpin()
	return lastPayAt ~= before
end

-- The live events are the fast signal, but they only exist for clears this
-- generation has seen. A re-execute leaves the SERVER holding a half-finished run
-- - stages already cleared, barriers already down - while RUN.cleared is empty, so
-- the walk stalls on stage 1 waiting for a wave that will never spawn again. That
-- read as "stage 1 did not fall in 8s" at 88K power against a 105 HP wave.
-- `CompletedStages` is the same list a round trip behind, and reconciling against
-- it costs nothing. The world-local and the global index are both accepted: world
-- 1 cannot tell them apart and no other world has been walked yet.
local function syncCleared(d, world, list)
	local comp = d.CompletedStages
	comp = comp and (comp[world] or comp[tostring(world)])
	if type(comp) ~= "table" then return end
	for i, s in ipairs(list) do
		if comp[i] == true or comp[s] == true then
			RUN.cleared[s] = true
			if s > RUN.deepest then RUN.deepest = s end
			if s > STATE.frontier then STATE.frontier = s end
		end
	end
end

local function raidPass()
	local d = refresh()
	local world = tonumber(d.CurrentWorld) or 1
	local list = stagesOfWorld(world)
	if #list == 0 then note("no stages in world " .. world) return end
	syncCleared(d, world, list)

	local target = list[1]
	if CONFIG.stageMode == "Manual" then
		target = list[math.clamp(CONFIG.stageTarget, 1, #list)]
		STATE.target = CONFIG.stageTarget
	else
		local pickedStage, _, pickedTime = pickTarget()
		target = pickedStage or list[1]
		STATE.runSecs = pickedTime or 0
		for i, s in ipairs(list) do if s == target then STATE.target = i end end
	end

	STATE.phase = "raid"
	local t0 = os.clock()
	local deepest = 0

	for _, s in ipairs(list) do
		if s > target then break end
		if not CONFIG.auto or GEN ~= _G.__HEROEVO then break end
		if RUN.cleared[s] then
			deepest = s
		else
			local folder = stageFolder(world, s)
			if not folder then note("stage " .. s .. " is not in the map") break end
			note("stage " .. s)
			enterStage(folder)
			local budget = math.min(CONFIG.stageTimeout, clearSecs(world, s, STATE.power) * 2.5 + 4)
			local t = os.clock()
			while not RUN.cleared[s] and os.clock() - t < budget do task.wait(0.1) end
			if not RUN.cleared[s] then
				-- Before giving up, ask the server: a stage cleared moments before
				-- this generation started produces no event at all, and treating
				-- that as a wall stops the walk one stage into a run that is
				-- already half done.
				syncCleared(refresh(true), world, list)
			end
			if RUN.cleared[s] then
				deepest = s
			else
				note(("stage %d did not fall in %.0fs"):format(s, os.clock() - t))
				break
			end
		end
	end

	unpin()
	STATE.deepest = deepest
	if deepest > 0 then
		local folder = stageFolder(world, deepest)
		if folder then
			STATE.phase = "claim"
			claimPad(folder)
			STATE.runs = STATE.runs + 1
			STATE.runSecs = os.clock() - t0
		end
	end
	STATE.phase = "idle"
end

--------------------------------------------------------------------------------
-- training
--------------------------------------------------------------------------------

local function worldOfInstance(inst)
	local map3 = workspace:FindFirstChild("Map3")
	local map2 = workspace:FindFirstChild("MapTest")
	local map1 = workspace:FindFirstChild("Map")
	if map3 and inst:IsDescendantOf(map3) then return 3 end
	if map2 and inst:IsDescendantOf(map2) then return 2 end
	if map1 and inst:IsDescendantOf(map1) then return 1 end
	return 1
end

-- A zone above the rebirth count sets the multiplier to 1, which is worse than
-- entering none, and a zone with a GamepassId is the Robux one. Both are read off
-- the CONFIG entry, never off the model's name.
local function bestZone(world, rebirths)
	local best, bestMulti = nil, -1
	for _, model in ipairs(CollectionService:GetTagged("TrainingZone")) do
		local id = model:GetAttribute("ZoneId")
		local cfg
		if id and ZoneConfig then
			cfg = ZoneConfig[id] or ZoneConfig[tonumber(id)] or ZoneConfig[tostring(id)]
		end
		if cfg and not cfg.GamepassId then
			local multi = tonumber(cfg.Multiplier) or 1
			local need = tonumber(cfg.RebirthRequirement) or 0
			if worldOfInstance(model) == world and need <= rebirths and multi > bestMulti then
				best, bestMulti = model, multi
			end
		end
	end
	return best, bestMulti
end

local function trainPass(secs)
	local d = refresh()
	local zone, multi = bestZone(tonumber(d.CurrentWorld) or 1, STATE.rebirths)
	if not zone then note("no training zone reachable") return end
	STATE.zone = tostring(zone:GetAttribute("ZoneId"))
	STATE.zoneMulti = multi
	STATE.phase = "train"
	local ok, pos = pcall(function() return zone:GetPivot().Position end)
	if not ok then return end
	pin(pos + Vector3.new(0, 4, 0))
	local t = os.clock()
	while os.clock() - t < secs and CONFIG.auto and GEN == _G.__HEROEVO do task.wait(0.2) end
	unpin()
	STATE.phase = "idle"
end

--------------------------------------------------------------------------------
-- spending
--------------------------------------------------------------------------------

local function itemEntry(id)
	if not ItemConfig then return nil end
	return ItemConfig[tostring(id)] or ItemConfig[tonumber(id) or -1]
end

local function promptIn(model)
	for _, x in ipairs(model:GetDescendants()) do
		if x:IsA("ProximityPrompt") then return x end
	end
	return nil
end

-- The stands carry an `ItemId` ATTRIBUTE that is a string, and three of them in
-- each world hold ids like 5000 / 9999 / 10000 that are not in ItemConfig at all -
-- the limited and event heroes. Anything the config does not know is skipped.
local function itemStands(world)
	local name = (world == 1 and "Map") or (world == 2 and "MapTest") or "Map3"
	local root = workspace:FindFirstChild(name)
	local out = {}
	if not root then return out end
	for _, v in ipairs(CollectionService:GetTagged("ItemStand")) do
		if v:IsDescendantOf(root) then
			local id = tostring(v:GetAttribute("ItemId"))
			if itemEntry(id) then out[id] = v end
		end
	end
	return out
end

local function canSpend(cost)
	return (STATE.wins - CONFIG.winsKeep) >= cost
end

-- The stand's prompt buys AND equips in one press, and an item stays unlocked
-- forever, so nothing has to be reserved for what is currently worn. The ladder is
-- walked cheapest-first: in the sister clickers a "best affordable" jump was
-- silently refused because the shop only ever answers for the next rung, and a
-- skipped rung has to be paid for later anyway.
local function morphPass()
	if not (CONFIG.morphs and ItemConfig) then return end
	local d = refresh(true)
	local unlocked = d.UnlockedItems or {}
	local stands = itemStands(tonumber(d.CurrentWorld) or 1)
	local wanted = {}
	for id, stand in pairs(stands) do
		local e = itemEntry(id)
		local cost = e and tonumber(e.UnlockCost)
		local gain = e and tonumber(e.Gain)
		if cost and gain and gain > (STATE.gain or 0) and not unlocked[id] then
			wanted[#wanted + 1] = { id = id, cost = cost, gain = gain, stand = stand, name = e.Name }
		end
	end
	table.sort(wanted, function(a, b) return a.cost < b.cost end)

	local bought = 0
	for _, w in ipairs(wanted) do
		if bought >= 4 then break end
		refresh(true)
		if not canSpend(w.cost) then break end
		local prompt = promptIn(w.stand)
		local ok, pos = pcall(function() return w.stand:GetPivot().Position end)
		if prompt and ok then
			STATE.phase = "shop"
			note("morph " .. tostring(w.name) .. " (" .. short(w.cost) .. ")")
			pin(pos + Vector3.new(0, 3, 4))
			task.wait(1.2)
			pcall(fireproximityprompt, prompt)
			task.wait(1.0)
			unpin()
			local after = refresh(true)
			if (after.UnlockedItems or {})[w.id] then
				STATE.spent = STATE.spent + w.cost
				bought = bought + 1
			else
				note("morph " .. tostring(w.name) .. " refused")
				break
			end
		end
	end
	STATE.phase = "idle"
end

-- An already-owned morph is free to put back on, so a rejoin that lands on a weak
-- one is corrected without spending anything.
local function equipBestOwned()
	if not (CONFIG.morphs and ItemConfig) then return end
	local d = refresh()
	local unlocked = d.UnlockedItems or {}
	local best, bestGain
	for id in pairs(unlocked) do
		local e = itemEntry(id)
		local g = e and tonumber(e.Gain)
		if g and g > (bestGain or -1) then best, bestGain = id, g end
	end
	if not best or (bestGain or 0) <= (STATE.gain or 0) then return end
	local stand = itemStands(tonumber(d.CurrentWorld) or 1)[best]
	if not stand then return end
	local prompt = promptIn(stand)
	if not prompt then return end
	local ok, pos = pcall(function() return stand:GetPivot().Position end)
	if not ok then return end
	pin(pos + Vector3.new(0, 3, 4))
	task.wait(1.2)
	pcall(fireproximityprompt, prompt)
	task.wait(0.6)
	unpin()
	refresh(true)
end

-- Every egg with a numeric wins Cost is fair game; the Robux ones carry no Cost at
-- all, so a plain "cheapest" sort would put them first. Buying is not hatching -
-- TryPurchaseEgg only fills the inventory and HatchEgg is what produces the pet.
--
-- The pets are worth more here than their price suggests: the 10-wins Basic Egg
-- took PetMultiplier from 1.1 to 2.7 in a single hatch, and PetMultiplier feeds
-- TotalMultiplier, which multiplies the power tick. That is why this is on.
--
-- An egg tier goes stale once its own pool has nothing left to give, and there is
-- no ownership flag that says so - only the multiplier standing still. Three
-- hatches in a row that do not move it retire that tier until a better one is
-- affordable. Never on the first failure: a hatch can legitimately roll a
-- duplicate, and blacklisting on one roll is how a picker deletes its own best
-- targets.
local eggStrikes = {}
local eggTopSeen = -1

local function eggPass()
	if not (CONFIG.eggs and EggsConfig and R.TryPurchaseEgg and R.HatchEgg) then return end
	local d = refresh(true)

	-- A tier retired at one balance is worth another look once a better one comes
	-- into reach, so the strikes are dropped the moment a more expensive egg
	-- becomes affordable rather than being kept for the whole session.
	local top = -1
	for _, e in pairs(EggsConfig) do
		local cost = tonumber(e.Cost)
		if cost and e.Currency == "Wins" and canSpend(cost) and cost > top then top = cost end
	end
	if top > eggTopSeen then
		eggTopSeen = top
		eggStrikes = {}
	end

	local best, bestCost
	for id, e in pairs(EggsConfig) do
		local cost = tonumber(e.Cost)
		if cost and e.Currency == "Wins" and canSpend(cost)
			and (eggStrikes[id] or 0) < 3 and cost > (bestCost or -1) then
			best, bestCost = id, cost
		end
	end
	if not best then return end

	local stand
	for _, v in ipairs(CollectionService:GetTagged("EggStand")) do
		local id = v:GetAttribute("EggId") or v:GetAttribute("Id") or v.Name
		if tostring(id) == best then stand = v end
	end

	STATE.phase = "eggs"
	local before = tonumber(d.PetMultiplier) or 1
	if stand then
		local ok, pos = pcall(function() return stand:GetPivot().Position end)
		if ok then pin(pos + Vector3.new(0, 3, 4)) task.wait(1.0) end
	end
	pcall(function() R.TryPurchaseEgg:FireServer(best, 1) end)
	task.wait(0.6)
	pcall(function() R.HatchEgg:FireServer(best, true) end)
	task.wait(1.0)
	unpin()

	local after = refresh(true)
	if (tonumber(after.PetMultiplier) or 1) > before then
		eggStrikes[best] = 0
		STATE.spent = STATE.spent + bestCost
		note("egg " .. tostring(best) .. " -> pets x" .. tostring(after.PetMultiplier))
	else
		eggStrikes[best] = (eggStrikes[best] or 0) + 1
		STATE.spent = STATE.spent + bestCost
		note("egg " .. tostring(best) .. " gave nothing (" .. eggStrikes[best] .. "/3)")
	end
	STATE.phase = "idle"
end

local function petPass()
	if not CONFIG.pets then return end
	if R.EquipBestPets then pcall(function() R.EquipBestPets:FireServer() end) end
	if R.EquipBestArtifacts then pcall(function() R.EquipBestArtifacts:FireServer() end) end
end

-- The gate is the LEVEL and the config's threshold is compared against it, not
-- against the wins: RequestRebirth answered a plain `false` at 147 wins and level
-- 5 against a threshold of 10, and `true` at level 10.
--
-- What it actually costs, measured across one call with the farm switched off:
-- Power 8,532 -> 0 and Level 10 -> 3, while Wins (100), every unlocked morph, the
-- equipped morph, the pets and HighestStageEverReached all survived untouched and
-- TotalMultiplier went 1.1 -> 2.2. So the only price is the power bar, and it
-- regrows at twice the old rate - which is why this is on by default and why the
-- cycle above trains rather than runs until the frontier is back.
local function rebirthPass()
	if not (CONFIG.rebirth and R.RequestRebirth and RebirthConfig) then return end
	local d = refresh(true)
	local have = tonumber(d.Rebirths) or 0
	local need = 0
	local ok, v = pcall(RebirthConfig.getThreshold, have)
	if ok then need = tonumber(v) or 0 end
	if need <= 0 or (tonumber(d.Level) or 0) < need then return end
	local ok2, res = pcall(function() return R.RequestRebirth:InvokeServer() end)
	if ok2 and res then
		note("rebirth " .. have .. " -> " .. (have + 1))
		RUN.cleared = {}
		RUN.deepest = 0
		refresh(true)
	end
end

-- Crossing costs nothing; the gate is `ClearedWorlds[n-1]`, which the game's own
-- WorldsController checks before it will even fire the remote.
local function worldPass()
	if not (CONFIG.worlds and R.RequestWorldChange) then return end
	local d = refresh()
	local world = tonumber(d.CurrentWorld) or 1
	local cleared = d.ClearedWorlds or {}
	if cleared[world] ~= true and cleared[tostring(world)] ~= true then return end
	local ok, res = pcall(function() return R.RequestWorldChange:InvokeServer(world + 1) end)
	if ok and res then
		note("world " .. world .. " -> " .. (world + 1))
		stageCache = {}
		RUN.cleared = {}
		refresh(true)
	end
end

local function freePass()
	if not CONFIG.freebies then return end
	if R.ClaimOfflineEarnings then pcall(function() R.ClaimOfflineEarnings:FireServer() end) end
	if R.ClaimGroupReward then pcall(function() R.ClaimGroupReward:FireServer() end) end
	-- A claim remote fired bare claims nothing here: it wants the reward's index,
	-- and the state remote is the only thing that says which ones are ripe.
	if R.GetPlaytimeRewardsState and R.ClaimPlaytimeReward and Playtime then
		local ok, st = pcall(function() return R.GetPlaytimeRewardsState:InvokeServer() end)
		if ok and type(st) == "table" then
			local claimed = st.Claimed or {}
			local first = tonumber(st.FirstPlayTimestamp) or os.time()
			local elapsed = os.time() - first
			for i = 1, (tonumber(Playtime.TOTAL_REWARDS) or 12) do
				local e = Playtime[i] or Playtime[tostring(i)]
				local need = e and (tonumber(e.Time) or tonumber(e.Seconds) or tonumber(e.UnlockAt))
				local done = claimed[i] or claimed[tostring(i)]
				if e and not done and (need == nil or elapsed >= need) then
					pcall(function() R.ClaimPlaytimeReward:FireServer(i) end)
					task.wait(0.2)
				end
			end
		end
	end
end

local function unstuck()
	CONFIG.auto = false
	unpin()
	local _, hrp, hum = char()
	if hum then
		hum.PlatformStand = false
		hum.WalkSpeed = 22
		pcall(function() hum:ChangeState(Enum.HumanoidStateType.GettingUp) end)
	end
	if hrp then hrp.Anchored = false end
	local scripts = plr:FindFirstChild("PlayerScripts")
	local pm = scripts and scripts:FindFirstChild("PlayerModule")
	if pm then pcall(function() require(pm):GetControls():Enable() end) end
	STATE.phase = "idle"
	note("unstuck, auto off")
end

--------------------------------------------------------------------------------
-- loops
--------------------------------------------------------------------------------

-- `needsBody` is the whole point of this helper. The first version held every
-- timer behind `not STATE.busy` so that nothing could fight the cycle for the
-- character - but the cycle sets `busy` for the WHOLE raid, shop and training
-- sequence and drops it for 0.4s between passes, so the rebirth check, the world
-- change and the free rewards effectively never ran. It looked like the script had
-- simply decided not to rebirth. Only a pass that moves the character has to wait.
local function loop(sec, key, fn, needsBody)
	task.spawn(function()
		while GEN == _G.__HEROEVO do
			if CONFIG.auto and (key == nil or CONFIG[key]) and not (needsBody and STATE.busy) then
				local ok, err = pcall(fn)
				if not ok then note(tostring(key) .. " failed: " .. tostring(err)) end
			end
			task.wait(sec)
		end
	end)
end

-- The read-out has to be live whether the farm runs or not, so this one is not
-- routed through loop().
task.spawn(function()
	local lastW, lastP, lastT = nil, nil, os.clock()
	while GEN == _G.__HEROEVO do
		pcall(refresh)
		local now = os.clock()
		local dt = now - lastT
		if dt >= 4 then
			if lastW then STATE.winRate = math.max(0, (STATE.wins - lastW) / dt) end
			if lastP then STATE.powerRate = math.max(0, (STATE.power - lastP) / dt) end
			lastW, lastP, lastT = STATE.wins, STATE.power, now
		end
		if CONFIG.stageMode == "Auto" and not STATE.busy then
			local s, _, t = pickTarget()
			if s then STATE.runSecs = t or 0 end
		end
		task.wait(1)
	end
end)

-- There is one body, so one thread owns it: the cycle runs the raid, the shop and
-- the training back to back rather than letting three loops pull in opposite
-- directions. Everything that does not move the character sits on its own timer.
task.spawn(function()
	while GEN == _G.__HEROEVO do
		if CONFIG.auto and (CONFIG.stages or CONFIG.train or CONFIG.morphs) then
			STATE.busy = true

			-- A rebirth wipes the Power and the picker collapses back to stage 1,
			-- which pays 1. Measured: 8,532 power to 0 for a permanent x2, so the
			-- climb back is quick - but only if the time goes into training
			-- instead of into runs worth a single win. The run resumes by itself
			-- once the target is within rebuildGap of the deepest stage ever
			-- reached, so nothing has to remember that a rebirth happened.
			local doRaid = CONFIG.stages
			if doRaid and CONFIG.train and CONFIG.trainSecs > 0 and STATE.frontier > 0 then
				local t = pickTarget()
				if t and (STATE.frontier - t) >= CONFIG.rebuildGap then
					doRaid = false
					note("rebuilding power, stage " .. tostring(t) .. " of " .. tostring(STATE.frontier))
				end
			end

			if doRaid then
				local ok, err = pcall(raidPass)
				if not ok then note("raid failed: " .. tostring(err)) end
			end
			if CONFIG.rebirth then
				local ok, err = pcall(rebirthPass)
				if not ok then note("rebirth failed: " .. tostring(err)) end
			end
			if CONFIG.morphs then
				local ok, err = pcall(morphPass)
				if not ok then note("shop failed: " .. tostring(err)) end
			end
			if CONFIG.eggs then pcall(eggPass) end
			if CONFIG.train and CONFIG.trainSecs > 0 then
				local ok, err = pcall(trainPass, CONFIG.trainSecs)
				if not ok then note("train failed: " .. tostring(err)) end
			end
			STATE.busy = false
		else
			unpin()
		end
		task.wait(0.4)
	end
end)

-- Rebirth is NOT on a timer. It wipes the power bar, so firing it halfway through
-- a run strands the walk in a stage it can no longer clear; it belongs immediately
-- after the cash-out, which is where the cycle calls it. Same lesson as spinjitsu.
loop(25, "worlds", worldPass)
loop(30, "pets", petPass)
loop(180, "freebies", freePass)
loop(45, "morphs", equipBestOwned, true)

--------------------------------------------------------------------------------
-- panel
--------------------------------------------------------------------------------

local UI = (_G.__SEL and _G.__SEL.ui) or loadstring(readfile("ui-template.lua"))()

if _G.__HEROEVO_WIN then pcall(function() _G.__HEROEVO_WIN:Destroy() end) end

-- `gethui()` is not always safe to CALL. In this game it throws
-- `invalid argument #1 to 'cloneref' (Instance expected, got nil)` because the
-- hidden container it clones does not exist here, and the usual
-- `(gethui and gethui()) or CoreGui` idiom does not survive that - the guard only
-- checks that the function exists, not that it works.
local hiddenRoot
pcall(function() hiddenRoot = gethui and gethui() end)

for _, root in ipairs({ hiddenRoot or game:GetService("CoreGui"), game:GetService("CoreGui") }) do
	if root then
		for _, g in ipairs(root:GetChildren()) do
			if g.Name == "HeroEvoPanel" then pcall(function() g:Destroy() end) end
		end
	end
end

-- Every switch on this panel survives a rejoin. UI.config merges the saved file
-- into CONFIG HERE, before the panel is built - the controls read their initial
-- value out of CONFIG when they are created, so they come up on the saved state by
-- themselves and nothing below had to be told about any of it.
UI.config("heroevo", CONFIG)

local win = UI.Window({
	name = "HeroEvoPanel",
	title = "HERO", accentTitle = "EVO", subtitle = "seltonmt",
	badge = "🦸", width = 820, height = 582,
})
_G.__HEROEVO_WIN = win

local page = win:Page("FARM", UI.icon.bolt)

local main = page:Card("LOOP", 1):Accent()
main:Toggle("AUTO", CONFIG.auto, function(v)
	CONFIG.auto = v
	STATE.phase = v and "farming" or "idle"
	if not v then unpin() end
	note(v and "running" or "stopped")
end, "raid the stage chain, shop, train, repeat", UI.theme.good)
main:Toggle("Stage runs", CONFIG.stages, function(v) CONFIG.stages = v end,
	"walks the gates in order and claims the deepest pad - the only income", UI.theme.good)
main:Toggle("Training", CONFIG.train, function(v) CONFIG.train = v end,
	"the only source of Power, and Power is the damage")
main:Slider("Train secs/run", 0, 60, CONFIG.trainSecs, function(v) CONFIG.trainSecs = v end)
main:Dropdown("Target stage", { "Auto", "Manual" }, CONFIG.stageMode, function(v)
	CONFIG.stageMode = v
end)
main:Stepper("Manual stage", function() return tostring(CONFIG.stageTarget) end, function(dir)
	CONFIG.stageTarget = math.clamp(CONFIG.stageTarget + dir, 1, 15)
end, "only used while Target stage is Manual")
main:Slider("Max run secs", 20, 240, CONFIG.maxRunSecs, function(v) CONFIG.maxRunSecs = v end)

local spend = page:Card("SPENDING", 2)
spend:Toggle("Morphs", CONFIG.morphs, function(v) CONFIG.morphs = v end,
	"climbs the hero ladder cheapest-first; Gain is the whole power engine", UI.theme.good)
spend:Toggle("Eggs", CONFIG.eggs, function(v) CONFIG.eggs = v end,
	"wins-priced eggs only - the 10-wins Basic took pets x1.1 to x2.7 in one hatch", UI.theme.good)
spend:Toggle("Equip best", CONFIG.pets, function(v) CONFIG.pets = v end,
	"EquipBestPets and EquipBestArtifacts, both free")
spend:Toggle("Auto rebirth", CONFIG.rebirth, function(v) CONFIG.rebirth = v end,
	"gated on your LEVEL, not your wins - it costs only the power, which comes back at double", UI.theme.good)
spend:Stepper("Rebuild gap", function() return tostring(CONFIG.rebuildGap) end, function(dir)
	CONFIG.rebuildGap = math.clamp(CONFIG.rebuildGap + dir, 1, 10)
end, "after a rebirth, train instead of running while the target is this far below your best stage")
spend:Toggle("Travel worlds", CONFIG.worlds, function(v) CONFIG.worlds = v end,
	"moves on as soon as the previous world is cleared; costs nothing")
spend:Toggle("Free rewards", CONFIG.freebies, function(v) CONFIG.freebies = v end,
	"playtime, offline earnings and the group reward", UI.theme.good)

local extra = page:Card("MANUAL", 1)
extra:Button("Run once", function() task.spawn(raidPass) end)
extra:Button("Shop now", function() task.spawn(morphPass) end)
extra:Button("Claim rewards", function() task.spawn(freePass) end)
extra:Button("Rebirth now", function()
	task.spawn(function()
		local was = CONFIG.rebirth
		CONFIG.rebirth = true
		rebirthPass()
		CONFIG.rebirth = was
	end)
end)
extra:Button("Unstuck", unstuck, UI.theme.bad)

local out = page:Card("STATUS", 0):Readout(13, function(text)
	if text:find("^AUTO") then return UI.theme.good end
	return nil
end)

task.spawn(function()
	while GEN == _G.__HEROEVO do
		local list = stagesOfWorld(STATE.world)
		local lines = {
			CONFIG.auto and "AUTO RUNNING" or "STOPPED",
			"  phase     " .. tostring(STATE.phase),
			"  world     " .. tostring(STATE.world) .. "   target stage " .. tostring(STATE.target)
				.. " of " .. tostring(#list) .. "   run ~" .. string.format("%.0fs", STATE.runSecs or 0),
			"  power     " .. short(STATE.power) .. "   " .. short(STATE.powerRate) .. "/s",
			"  wins      " .. short(STATE.wins) .. "   " .. short(STATE.winRate) .. "/s",
			"  morph     " .. tostring(STATE.item) .. "   gain " .. short(STATE.gain),
			"  zone      " .. tostring(STATE.zone) .. "   x" .. tostring(STATE.zoneMulti)
				.. "   total x" .. tostring(STATE.mult),
			"  level     " .. tostring(STATE.level) .. "   rebirths " .. tostring(STATE.rebirths),
			"  deepest   " .. tostring(STATE.deepest) .. "   best ever " .. tostring(STATE.frontier),
			"  last pay  " .. short(STATE.lastPay) .. "   runs " .. tostring(STATE.runs),
			"  earned    " .. short(STATE.earned) .. "   spent " .. short(STATE.spent),
			"  pets      x" .. tostring(STATE.petMult),
			"  " .. tostring(STATE.note),
		}
		pcall(function() out:set(lines) end)
		pcall(function()
			win:SetStatus(string.format("%s wins   power %s   stage %s   lv%s   %s",
				short(STATE.wins), short(STATE.power), tostring(STATE.target),
				tostring(STATE.level), tostring(STATE.phase)))
		end)
		pcall(function()
			win:SetStat(1, short(STATE.wins), "wins")
			win:SetStat(2, short(STATE.power), "power")
			win:SetStat(3, tostring(STATE.rebirths), "rebirths")
		end)
		task.wait(0.5)
	end
end)

pcall(function()
	win:SetMaster(CONFIG.auto, "Auto Farm")
	win:OnMaster(function(on)
		CONFIG.auto = on
		STATE.phase = on and "farming" or "idle"
		if not on then unpin() end
	end)
end)

pcall(function() win:Home() end)

win:Refresh()

--------------------------------------------------------------------------------

_G.__HEROEVO_DBG = {
	CONFIG = CONFIG, STATE = STATE, RUN = RUN,
	refresh = refresh, data = data, short = short, alya = alya,
	stageFolder = stageFolder, stagesOfWorld = stagesOfWorld, syncCleared = syncCleared,
	stageHP = stageHP, stageWins = stageWins, clearSecs = clearSecs,
	runLength = runLength, pickTarget = pickTarget,
	enterStage = enterStage, claimPad = claimPad, raidPass = raidPass,
	bestZone = bestZone, trainPass = trainPass, worldOfInstance = worldOfInstance,
	morphPass = morphPass, equipBestOwned = equipBestOwned, eggPass = eggPass,
	petPass = petPass, rebirthPass = rebirthPass, worldPass = worldPass,
	freePass = freePass, unstuck = unstuck,
	pin = pin, unpin = unpin, itemStands = itemStands, itemEntry = itemEntry,
}

print("[heroevo] gen " .. GEN .. " ready - RightShift for the panel")
