--[[ choptrees.lua - "+1 Chop Trees for Treasure" (place 110730550789828, ArcHaven)

  The loop the game actually runs:

      stand on a TRAIN pad   -> TrainHit(mat) -> Strength (+XP -> Level)
      cross a StartLine      -> a CHOP RUN opens
      swing                  -> the CLIENT fells the trees and reports the zones
      ChopTreeHit(zones,seq) -> wood + a roll for TREASURE drops
      LootTreasure(dropId)   -> carried (cap = 3 + backpack upgrade)
      TeleportToZone(zone)   -> home, and the carried treasure lands in the STOCK
      SellTreasure(id)       -> CASH, standing at the TreasureMarket
      Cash                   -> choppers (the strength multiplier), axes, upgrades
      Rebirth (LEVEL gate)   -> stronger train pads

  Everything below was measured against the server through the bridge before it was
  written down. Six findings shape this file:

  * TRAINING IS POSITION GATED AND HARD THROTTLED. 20 TrainHit calls fired 60 studs
    above the pad credited exactly 0. On the pad the server credits ~3.0 hits/s and
    no more: 48 calls/s and 264 calls/s both measured 3.00/s, while the game's own
    client loop does 2.5/s by itself. So driving it is worth +20% and nothing else -
    the real levers are the pad's reward, the chopper and the rebirth count.

  * THE TREE HP IS SIMULATED ENTIRELY IN THE CLIENT. `applyTreeHit` subtracts the
    player's Strength from a LOCAL table and, when a tree reaches 0, appends that
    tree's ZONE NUMBER to an array. The server only ever receives
    `ChopTreeHit(<array of zone numbers>, <sequence>)` - it holds no copy of any
    tree. That is the game's own design, not a trick, and the honest farm below
    reports exactly what a real swing would have reported.

  * THE ACTIVE RUN IS THE REAL GATE. Outside a run the remote credits nothing at
    all - measured 0 wood, repeatedly - and that cost a wrong conclusion here until
    the character was found standing back on the lobby side of the StartLine. Every
    chop pass therefore checks the run first and re-enters by CROSSING the line.

  * THE SERVER DOES NOT VALIDATE THE ZONE, AND IT CAPS THE COUNT AT 13. Claiming a
    zone-52 tree while standing in zone 1 paid the full 483,000,000 wood, and the
    drop that came with it was a `Nexus Heart` worth 7.6e21 cash against 11 for a
    zone-1 `Coin Pouch`. The entry count is capped: 1/5/13 entries credited 1/5/13,
    while 20, 50 and 1000 entries all credited exactly 13. That is the TURBO page -
    off by default, in no preset, with the measurements printed beside it.

  * CASH IS THE ONLY CURRENCY THAT MATTERS. Choppers, axes AND upgrades all check
    `leaderstats.Cash`; wood buys nothing but artifacts. So the treasure half is the
    whole economy and the wood half is decoration - worth knowing before anyone
    optimises the wrong number.

  * A REBIRTH TAKES THE AXES, AND THE GAME DOES NOT SAY SO. Its own warning reads
    "Rebirthing resets Strength!"; measured, it resets Strength, the LEVEL (203 ->
    1) AND every axe (11 owned -> sword1 alone), while cash, wood, the chopper, the
    pets and all six upgrades survive. On a thin balance that is the income thrown
    away for a multiplier, so `rebirthAxeReserve` holds the rebirth until the cash
    covers re-climbing the ladder.

  * SELLING IS POSITION GATED, LOOTING AND UPGRADING ARE NOT. `SellTreasure(id)`
    fired away from the market changes nothing; standing at it, it paid 7.6e21 on
    the first call. `LootTreasure(dropId)` and `BuyUpgrade(id)` both work from
    anywhere.

  Never spends Robux: every pad carrying a `pass` flag (Mythic, Admin and the five
  RobuxTrainTree pads), the `productId` on every chopper, the rebirth SKIP product
  (49 R$), the Robux eggs and `ClaimRobuxHatch`. The pad table below carries the
  flag explicitly because the gating lives in the client's own table and nowhere on
  the instance - it is copied from that table, never inferred from the name.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local plr = Players.LocalPlayer

local GEN = (_G.__CHOPTREES or 0) + 1
_G.__CHOPTREES = GEN

--------------------------------------------------------------------------------
-- config
--------------------------------------------------------------------------------

local CONFIG = {
	auto = false,

	train = true,        -- stand on the best pad and hold the 3/s ceiling
	trainSecs = 25,      -- seconds of training per cycle
	chop = true,         -- open a run and chop what is actually in reach
	chopSecs = 35,       -- seconds of chopping per cycle
	treasure = true,     -- loot drops, bank them, sell the stock
	spend = true,        -- choppers -> upgrades -> axes
	pets = true,         -- hatch the best affordable egg and wear the best ones
	worlds = true,       -- unlock and travel to the deepest world the level allows
	rebirth = true,      -- gated on the LEVEL; it also wipes every axe - see below
	rebirthAxeReserve = 8, -- only rebirth while cash covers re-buying the worn axe
	                       -- this many times over, because a rebirth takes them all
	freebies = true,     -- code, daily, offline earnings, group

	backpackFirst = true, -- backpack slots decide how much a run can carry home
	cashKeep = 0,         -- cash never spent

	-- TURBO. Off, and in no preset. See the header for the measurements.
	turbo = false,
	turboZone = 52,      -- the zone NUMBER claimed; 1..52, unvalidated by the server
	turboPerCall = 13,   -- the server's own cap; more is silently discarded
	turboGap = 0.1,      -- seconds between calls. 0.3 credits 100%, 0.1 credits
	                     -- 56% but moves more per second - see petPushPass
	finishTrips = 3,     -- market trips per FINISH sweep; the bag, not the drop
	                     -- rate, is what limits a single trip
	finishLoop = false,  -- keep sweeping instead of running once
	petPush = true,      -- mint wood for the next egg up; eggs are priced in WOOD
	petPushSecs = 90,    -- how long one minting push may run
	petPushCeiling = 1e14, -- do not aim at an egg that would take days: the wood
	                       -- curve clamps at zone 52, so anything past ~1e14 is out
	petBatches = 6,      -- HatchEggBatch(folder, 3) calls after the rung is known
	rebirthRush = false, -- fire the hole until the level requirement is met, then
	                     -- rebirth, and repeat - the leaderboard climb
	rebirthRushCount = 10, -- rebirths per rush
	rebirthRushSecs = 45,  -- give up on one climb after this and stop the rush
}

local STATE = {
	phase = "idle",
	note = "",
	strength = 0, cash = 0, wood = 0, level = 0, xp = 0, xpNeed = 0,
	rebirths = 0, chopper = "-", chopperBonus = 1, axe = "-",
	carried = 0, carryMax = 0, stock = 0,
	pets = 0, petsWorn = 0, petSlots = 1, totalMulti = 1,
	pad = "-", padReward = 0, zone = "Zone1", runActive = false,
	rebirthNeed = 0, finishStep = "-", rushed = 0,
	runs = 0, felled = 0, looted = 0, sold = 0, earned = 0, spent = 0,
	strengthRate = 0, cashRate = 0,
	busy = false, turboCalls = 0,
}

local function note(t)
	STATE.note = tostring(t)
end

--------------------------------------------------------------------------------
-- the pad table, copied out of the client's own TrainingSystem
--------------------------------------------------------------------------------
--
-- `pass = true` is the Robux gate. It is carried here explicitly because the
-- instance in the world has no attribute saying so - the whole gating table lives
-- in the client module - and a name check would break on the next pad they add.

local PADS = {
	{ mat = "TrainTree1",  reward = 1.5, need = 0 },
	{ mat = "TrainTree2",  reward = 2,   need = 2 },
	{ mat = "TrainTree3",  reward = 4,   need = 5 },
	{ mat = "TrainTree4",  reward = 6,   need = 8 },
	{ mat = "TrainTree5",  reward = 8,   need = 11 },
	{ mat = "TrainTree6",  reward = 11,  need = 13 },
	{ mat = "TrainTree7",  reward = 15,  need = 15 },
	{ mat = "TrainTree8",  reward = 20,  need = 17 },
	{ mat = "TrainTree9",  reward = 25,  need = 20 },
	{ mat = "TrainTree10", reward = 30,  need = 24 },
	{ mat = "TrainTree11", reward = 35,  need = 28 },

	{ mat = "TrainMatCommon",    reward = 1.5, need = 0 },
	{ mat = "TrainMatUncommon",  reward = 2,   need = 1 },
	{ mat = "TrainMatRare",      reward = 3,   need = 3 },
	{ mat = "TrainMatEpic",      reward = 4,   need = 5 },
	{ mat = "TrainMatLegendary", reward = 5,   need = 7 },

	{ mat = "TrainMatMythic",   reward = 36,  need = 0, pass = true },
	{ mat = "TrainMatAdmin",    reward = 150, need = 0, pass = true },
	{ mat = "RobuxTrainTree1",  reward = 10,  need = 0, pass = true },
	{ mat = "RobuxTrainTree2",  reward = 25,  need = 0, pass = true },
	{ mat = "RobuxTrainTree3",  reward = 50,  need = 0, pass = true },
	{ mat = "RobuxTrainTree4",  reward = 100, need = 0, pass = true },
	{ mat = "RobuxTrainTree5",  reward = 250, need = 0, pass = true },
}

--------------------------------------------------------------------------------
-- remotes and config modules
--------------------------------------------------------------------------------

local function waitFor(name, secs)
	local ok, inst = pcall(function()
		return ReplicatedStorage:WaitForChild(name, secs or 10)
	end)
	return ok and inst or nil
end

local R = {}
for _, n in ipairs({
	"TrainHit", "ChopTreeHit", "SellTreasure", "RequestSync", "AxeDataSync",
	"TreasureDrop", "BuyChopper", "EquipChopper", "BuyAxe", "EquipAxe",
	"PetAction",
}) do
	R[n] = waitFor(n, 10)
end

local RF = {}
for _, n in ipairs({
	"LootTreasure", "BuyUpgrade", "RebirthFunc", "RedeemCode", "TeleportToZone",
	"ClaimOfflineEarnings", "DailyClaimFunc", "GroupRewardClaim", "SpinAura",
	"UnlockZone", "HatchEgg", "HatchEggBatch",
}) do
	RF[n] = waitFor(n, 10)
end

-- A module-level `require` that never returns takes the whole script with it, so
-- every one of them runs in its own thread behind a wall clock cap.
local function req(inst, secs)
	if not inst then return nil end
	local done, ok, res = false, false, nil
	task.spawn(function()
		pcall(function() setthreadidentity(2) end)
		ok, res = pcall(require, inst)
		done = true
	end)
	local t = 0
	while not done and t < (secs or 6) do
		task.wait(0.1); t = t + 0.1
	end
	if not done or not ok then return nil end
	return res
end

local Shared = ReplicatedStorage:FindFirstChild("Shared")
local TreeZones = Shared and req(Shared:FindFirstChild("TreeZonesData"))
local Choppers  = Shared and req(Shared:FindFirstChild("ChoppersData"))
local Axes      = Shared and req(Shared:FindFirstChild("AxesData"))
local Upgrades  = Shared and req(Shared:FindFirstChild("UpgradesData"))
local Treasure  = Shared and req(Shared:FindFirstChild("TreasureData"))
local Levels    = Shared and req(Shared:FindFirstChild("PlayerLevels"))

--------------------------------------------------------------------------------
-- the oracle
--------------------------------------------------------------------------------
--
-- AxeDataSync is a server -> client push carrying the whole profile: wood, cash,
-- strength, level, rebirths, ownedChoppers, upgrades, treasureCarried,
-- treasureStock, treasureMax. RequestSync asks for a fresh one. The table is
-- REPLACED on every push, so nothing caches an inner table.

local PROFILE = nil
local lastSync = 0

if R.AxeDataSync then
	R.AxeDataSync.OnClientEvent:Connect(function(p)
		if type(p) == "table" and p.wood ~= nil then
			PROFILE = p
			lastSync = os.clock()
		end
	end)
end

local function requestSync()
	if R.RequestSync then pcall(function() R.RequestSync:FireServer() end) end
end

-- Waits for a FRESH push rather than returning whatever arrived last, because a
-- purchase confirmed against a stale profile reads as a refusal.
local function data(fresh)
	if fresh then
		local mark = lastSync
		for _ = 1, 4 do
			requestSync()
			local t = 0
			while lastSync == mark and t < 3 do task.wait(0.1); t = t + 0.1 end
			if lastSync ~= mark then break end
		end
	elseif os.clock() - lastSync > 3 then
		requestSync()
	end
	return PROFILE
end

local function count(t)
	local n = 0
	for _ in pairs(t or {}) do n = n + 1 end
	return n
end

--------------------------------------------------------------------------------
-- body control
--------------------------------------------------------------------------------

local function char()
	local c = plr.Character
	if not c then return nil, nil end
	return c, c:FindFirstChild("HumanoidRootPart")
end

-- The server validates against its own copy of the position, so a single CFrame
-- write is never enough for anything gated - it has to be held while the call goes
-- out. Everything that needs the body goes through this.
local function pinAt(cf, secs, fn)
	local _, hrp = char()
	if not hrp then return false end
	local con = RunService.Heartbeat:Connect(function()
		local _, h = char()
		if h then
			h.CFrame = cf
			h.AssemblyLinearVelocity = Vector3.zero
		end
	end)
	local ok, err = pcall(function()
		task.wait(secs or 0.6)
		if fn then fn() end
	end)
	con:Disconnect()
	if not ok then note("pin failed: " .. tostring(err)) end
	return ok
end

-- A warp that lands inside a trigger volume without travelling through its plane
-- is not a crossing, and the run never opens. Small steps on Heartbeat are.
local function glide(from, to, steps)
	local _, hrp = char()
	if not hrp then return end
	steps = steps or 16
	for i = 1, steps do
		local _, h = char()
		if not h then return end
		h.CFrame = CFrame.new(from:Lerp(to, i / steps))
		h.AssemblyLinearVelocity = Vector3.zero
		RunService.Heartbeat:Wait()
		RunService.Heartbeat:Wait()
	end
end

local function unstuck()
	CONFIG.auto = false
	local c, hrp = char()
	local hum = c and c:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.PlatformStand = false
		hum.Sit = false
		pcall(function() hum:ChangeState(Enum.HumanoidStateType.GettingUp) end)
	end
	if hrp then hrp.Anchored = false end
	local ps = plr:FindFirstChild("PlayerScripts")
	local pm = ps and ps:FindFirstChild("PlayerModule")
	if pm then pcall(function() req(pm, 3):GetControls():Enable() end) end
	STATE.busy = false
	STATE.phase = "idle"
	note("unstuck, auto off")
end

--------------------------------------------------------------------------------
-- the world
--------------------------------------------------------------------------------

local function areaFolders()
	local out = {}
	for _, d in ipairs(Workspace:GetChildren()) do
		if d.Name:match("^Zone%d+$") then out[#out + 1] = d end
	end
	table.sort(out, function(a, b) return a.Name < b.Name end)
	return out
end

-- The area the body is in, resolved the way the game's own CurrentZone does it:
-- by the nearest anchor part, never by a stored value.
local function currentArea()
	local _, hrp = char()
	if not hrp then return nil end
	local best, bestD = nil, math.huge
	for _, z in ipairs(areaFolders()) do
		for _, d in ipairs(z:GetChildren()) do
			if d:IsA("BasePart") and (d.Name == "StartLine" or d.Name == "SpawnLocation"
				or d.Name == "Spawn" or d.Name:match("^Treezone%d+$")) then
				local dist = (hrp.Position - d.Position).Magnitude
				if dist < bestD then best, bestD = z, dist end
			end
		end
	end
	return best
end

local function findPadPart(mat)
	for _, z in ipairs(areaFolders()) do
		for _, d in ipairs(z:GetDescendants()) do
			if d:IsA("BasePart") and d.Name == mat then return d end
		end
	end
	return nil
end

-- Highest reward whose rebirth requirement is met, Robux pads excluded, and only
-- pads that actually exist in this world - the deeper ones live in areas that are
-- still locked, so the table alone is not enough.
local function bestPad()
	local d = data()
	local reb = (d and d.rebirths) or 0
	local best, bestPart = nil, nil
	for _, p in ipairs(PADS) do
		if not p.pass and reb >= p.need then
			if (not best) or p.reward > best.reward then
				local part = findPadPart(p.mat)
				if part then best, bestPart = p, part end
			end
		end
	end
	return best, bestPart
end

-- StreamingEnabled is TRUE here, so "the StartLine is not there" means "the body
-- is not there" - the run entry failed with `no StartLine in Zone1` while Zone1
-- plainly has one, because the market trip had streamed it out. Positions are
-- therefore remembered the first time they are readable. The key carries a
-- version: a cache written by an older shape of this table outlives the code that
-- wrote it, and reading it back then errors in a script that was fine a minute ago.
local GEO = _G.__CHOPTREES_GEO
if type(GEO) ~= "table" or GEO.v ~= 1 then
	GEO = { v = 1, startLine = {}, market = nil }
	_G.__CHOPTREES_GEO = GEO
end

local function startLineFor(area)
	if not area then return nil, nil end
	local part = area:FindFirstChild("StartLine")
	if part and part:IsA("BasePart") then
		GEO.startLine[area.Name] = part.CFrame
		return part, part.CFrame
	end
	return nil, GEO.startLine[area.Name]
end

-- The run flag the client keeps is a side test against the StartLine's own plane:
-- more than 2 studs past it on the tree side counts as inside.
local function runSide()
	local area = currentArea()
	local _, cf = startLineFor(area)
	local _, hrp = char()
	if not (cf and hrp) then return nil end
	return cf:PointToObjectSpace(hrp.Position).Z
end

local function runActive()
	local s = runSide()
	return s ~= nil and s > 2
end

local function treezoneParts(area)
	local out = {}
	for _, d in ipairs((area or currentArea() or Workspace):GetChildren()) do
		if d:IsA("BasePart") and d.Name:match("^Treezone%d+$") then out[#out + 1] = d end
	end
	table.sort(out, function(a, b)
		return (tonumber(a.Name:match("%d+")) or 0) < (tonumber(b.Name:match("%d+")) or 0)
	end)
	return out
end

local function zoneIndexOf(part)
	if TreeZones and TreeZones.zoneIndexFromName then
		local ok, v = pcall(TreeZones.zoneIndexFromName, part.Name)
		if ok and type(v) == "number" then return v end
	end
	return tonumber(part.Name:match("%d+")) or 1
end

local function findMarket()
	for _, z in ipairs(areaFolders()) do
		local m = z:FindFirstChild("TreasureMarket")
		if m then
			local ok, pivot = pcall(function() return m:GetPivot().Position end)
			if ok and pivot then
				GEO.market = pivot
				return m, pivot
			end
		end
	end
	return nil, GEO.market
end

--------------------------------------------------------------------------------
-- training
--------------------------------------------------------------------------------
--
-- The ceiling is ~3.0 credited hits/s and it does not move: 48/s and 264/s both
-- measured 3.00/s. A 0.3s gap therefore sits just inside it and costs nothing,
-- where a per-frame burst throws away 95% of the calls and risks the queue.

local TRAIN_GAP = 0.3

-- True while "Run it once" owns the account. Declared this high because the
-- training and chopping loops read it to step aside mid-pass (a Lua local is
-- invisible above its own definition - declared in the FINISH section it
-- resolved to a nil global here). See finishPass for why it has to pause
-- everything else.
local FINISHING = false
local BODY_ACTIVE = false   -- the main body thread is mid-pass

local function trainPass(seconds)
	if not R.TrainHit then return end
	local pad, part = bestPad()
	if not (pad and part) then note("no usable train pad") return end
	STATE.pad, STATE.padReward = pad.mat, pad.reward
	STATE.phase = "training"

	local stand = part.Position + Vector3.new(0, -1.5, -1.0)
	local cf = CFrame.new(stand)
	local t0 = os.clock()
	pinAt(cf, 0.8)
	local con = RunService.Heartbeat:Connect(function()
		local _, h = char()
		if h then
			h.CFrame = cf
			h.AssemblyLinearVelocity = Vector3.zero
		end
	end)
	while os.clock() - t0 < (seconds or CONFIG.trainSecs)
		and CONFIG.auto and CONFIG.train and GEN == _G.__CHOPTREES and not FINISHING do
		pcall(function() R.TrainHit:FireServer(pad.mat) end)
		task.wait(TRAIN_GAP)
	end
	con:Disconnect()
end

--------------------------------------------------------------------------------
-- the chop run
--------------------------------------------------------------------------------

local SEQ = os.time() % 100000

local function nextSeq()
	SEQ = SEQ + 1
	return SEQ
end

-- Crossing, not warping. The run does not open for a body that teleported past
-- the plane without travelling through it.
local function enterRun()
	local area = currentArea()
	local _, cf = startLineFor(area)
	if not cf then note("no StartLine in " .. tostring(area and area.Name)) return false end
	local _, hrp = char()
	if not hrp then return false end

	local fwd = cf.LookVector
	local origin = cf.Position
	local outside = origin - fwd * 14 + Vector3.new(0, 3, 0)
	local inside  = origin + fwd * 16 + Vector3.new(0, 3, 0)
	-- The plane's own forward can point either way; take the side the trees are on.
	local tz = treezoneParts(area)[1]
	if tz and (tz.Position - inside).Magnitude > (tz.Position - outside).Magnitude then
		outside, inside = inside, outside
	end

	hrp.CFrame = CFrame.new(outside)
	task.wait(0.4)
	glide(outside, inside, 18)
	task.wait(0.6)
	STATE.runs = STATE.runs + 1
	return runActive()
end

-- Trees in reach of the body, the way the client counts them: everything whose
-- pivot is inside the chopper's reach. The zone comes from the Treezone part the
-- tree sits under, never from arithmetic on a name.
local function treesInReach(radius)
	local _, hrp = char()
	if not hrp then return {} end
	local out = {}
	for _, tzp in ipairs(treezoneParts()) do
		local zone = zoneIndexOf(tzp)
		for _, m in ipairs(tzp:GetChildren()) do
			if m:IsA("Model") then
				local ok, p = pcall(function() return m:GetPivot().Position end)
				if ok and (p - hrp.Position).Magnitude <= radius then
					out[#out + 1] = { model = m, zone = zone }
				end
			end
		end
	end
	return out
end

local function zoneHP(zone)
	if TreeZones and TreeZones.hpForZone then
		local ok, v = pcall(TreeZones.hpForZone, zone)
		if ok and type(v) == "number" then return v end
	end
	return math.huge
end

-- The honest swing: whatever the current Strength actually fells among the trees
-- standing in front of the body, reported exactly as the game's own client would
-- report it. Nothing is invented and nothing is claimed twice - a tree that was
-- reported is remembered for the rest of the run.
local chopped = {}

local function chopPass(seconds)
	if not R.ChopTreeHit then return end
	STATE.phase = "chopping"
	if not runActive() then
		if not enterRun() then note("could not open a run") return end
	end
	chopped = {}

	local d = data()
	local strength = (d and d.strength) or 0
	local t0 = os.clock()
	local swing = (TreeZones and TreeZones.TREE_SWING) or 0.5
	local mult = plr:GetAttribute("SwingSpeedMult")
	if type(mult) == "number" and mult > 0 then swing = swing / mult end

	while os.clock() - t0 < (seconds or CONFIG.chopSecs)
		and CONFIG.auto and CONFIG.chop and GEN == _G.__CHOPTREES and not FINISHING do

		if not runActive() then
			if not enterRun() then break end
		end

		local reach = treesInReach(18)
		local claim = {}
		for _, t in ipairs(reach) do
			if not chopped[t.model] and strength >= zoneHP(t.zone) then
				chopped[t.model] = true
				claim[#claim + 1] = t.zone
				if #claim >= 13 then break end   -- the server's own cap
			end
		end

		if #claim > 0 then
			pcall(function() R.ChopTreeHit:FireServer(claim, nextSeq()) end)
			STATE.felled = STATE.felled + #claim
		else
			-- Nothing left in reach that this Strength can fell: move along the
			-- row rather than standing still swinging at nothing.
			local tz = treezoneParts()
			if #tz > 0 then
				local pick = tz[math.random(1, #tz)]
				local ch, hrp = char()
				if hrp then
					-- LAND ON THE SURFACE, NOT IN THE PART. This used to warp to
					-- the part's CENTRE + 4, and for a thick zone block that is
					-- inside or under the ground - the "teleported under the map"
					-- the user kept seeing. Ray down from well above the part and
					-- stand on whatever it hits; no hit, no warp.
					local params = RaycastParams.new()
					params.FilterType = Enum.RaycastFilterType.Exclude
					params.FilterDescendantsInstances = { ch }
					local top = pick.Position + Vector3.new(0, pick.Size.Y / 2 + 60, 0)
					local hit = workspace:Raycast(top, Vector3.new(0, -200, 0), params)
					if hit then
						hrp.CFrame = CFrame.new(hit.Position + Vector3.new(0, 3.5, 0))
						hrp.AssemblyLinearVelocity = Vector3.zero
						task.wait(0.5)
					end
				end
			end
		end
		task.wait(swing)
	end
end

--------------------------------------------------------------------------------
-- treasure
--------------------------------------------------------------------------------

local PENDING = {}   -- dropId -> treasure id

if R.TreasureDrop then
	R.TreasureDrop.OnClientEvent:Connect(function(_, list)
		if type(list) ~= "table" then return end
		for _, d in ipairs(list) do
			if type(d) == "table" and d.dropId then
				PENDING[d.dropId] = d.id or true
			end
		end
	end)
end

local function carryMax(d)
	local m = (d and d.treasureMax) or 3
	return m
end

-- Looting needs no position at all - measured from the far side of the zone - so
-- this is a plain sweep over whatever the server announced.
local function lootPass()
	if not RF.LootTreasure then return end
	local d = data()
	local carried = count(d and d.treasureCarried)
	local cap = carryMax(d)
	for dropId in pairs(PENDING) do
		if carried >= cap then break end
		local done, ok = false, false
		task.spawn(function()
			ok = pcall(function() return RF.LootTreasure:InvokeServer(dropId) end)
			done = true
		end)
		local t = 0
		while not done and t < 5 do task.wait(0.1); t = t + 0.1 end
		PENDING[dropId] = nil
		if done and ok then
			carried = carried + 1
			STATE.looted = STATE.looted + 1
		end
		task.wait(0.15)
	end
end

-- Going home is what turns CARRIED treasure into STOCK. It is the game's own
-- return call, and without it the bag simply fills up and every later drop is
-- refused in silence.
local function bankPass()
	if not RF.TeleportToZone then return end
	local area = currentArea()
	local name = area and area.Name or "Zone1"
	local done = false
	task.spawn(function()
		pcall(function() RF.TeleportToZone:InvokeServer(name) end)
		done = true
	end)
	local t = 0
	while not done and t < 6 do task.wait(0.1); t = t + 0.1 end
	task.wait(1.2)
end

-- Selling IS position gated: the identical call refused away from the stand and
-- paid in full standing at it.
local function sellPass()
	if not R.SellTreasure then return end
	local d = data(true)
	local stock = d and d.treasureStock
	if count(stock) == 0 then return end
	local market, pivot = findMarket()
	if not pivot then note("no TreasureMarket found") return end

	STATE.phase = "selling"
	local cf = CFrame.new(pivot + Vector3.new(0, 2.5, 4))
	local before = (d and d.cash) or 0
	pinAt(cf, 1.2, function()
		for id in pairs(stock) do
			pcall(function() R.SellTreasure:FireServer(id) end)
			STATE.sold = STATE.sold + 1
			task.wait(0.35)
		end
		task.wait(1.0)
	end)
	local after = data(true)
	if after and after.cash and after.cash > before then
		STATE.earned = STATE.earned + (after.cash - before)
	end
end

--------------------------------------------------------------------------------
-- spending - cash is the only currency any shop here checks
--------------------------------------------------------------------------------

local function spendable(d)
	return math.max(0, ((d and d.cash) or 0) - CONFIG.cashKeep)
end

-- A chopper is a flat multiplier on every strength tick (chop2 = x2 measured,
-- chop23 = x500000 measured), so the best affordable one is always right and the
-- ladder never needs climbing rung by rung. `productId` is the Robux twin and is
-- never the path - the price field is the cash one.
local function chopperPass()
	if not (R.BuyChopper and Choppers and Choppers.Choppers) then return end
	local d = data()
	if not d then return end
	local owned = {}
	for _, v in pairs(d.ownedChoppers or {}) do owned[tostring(v)] = true end

	local have = 0
	for _, c in ipairs(Choppers.Choppers) do
		if owned[c.id] and (c.strength or 0) > have then have = c.strength end
	end

	local best = nil
	for _, c in ipairs(Choppers.Choppers) do
		if not owned[c.id] and type(c.price) == "number"
			and (c.strength or 0) > have and c.price <= spendable(d) then
			if (not best) or c.strength > best.strength then best = c end
		end
	end
	if not best then
		-- Nothing better to buy: make sure the best one OWNED is the one worn.
		local wear, ws = nil, -1
		for _, c in ipairs(Choppers.Choppers) do
			if owned[c.id] and (c.strength or 0) > ws then wear, ws = c, c.strength end
		end
		if wear and d.equippedChopper ~= wear.id and R.EquipChopper then
			pcall(function() R.EquipChopper:FireServer(wear.id) end)
		end
		return
	end

	pcall(function() R.BuyChopper:FireServer(best.id) end)
	task.wait(1.0)
	if R.EquipChopper then pcall(function() R.EquipChopper:FireServer(best.id) end) end
	task.wait(0.6)
	local after = data(true)
	-- Confirm on the thing the purchase changes, not on the balance: at this
	-- income a one-billion purchase can be invisible in the cash figure.
	if after and after.equippedChopper == best.id then
		STATE.spent = STATE.spent + best.price
		note("chopper " .. tostring(best.name) .. " x" .. tostring(best.strength))
	end
end

-- Backpack slots decide how much treasure a run brings home, which is the whole
-- income, so it is bought before anything cosmetic. Everything else follows in
-- the order the game lists it.
local UPGRADE_ORDER = { "backpack", "swingRange", "swingSpeed", "moveSpeed", "equip", "luck" }

local function upgradePass()
	if not (RF.BuyUpgrade and Upgrades) then return end
	local d = data()
	if not d then return end
	local levels = d.upgrades or {}

	local order = {}
	if CONFIG.backpackFirst then
		order[#order + 1] = "backpack"
		for _, id in ipairs(UPGRADE_ORDER) do
			if id ~= "backpack" then order[#order + 1] = id end
		end
	else
		order = UPGRADE_ORDER
	end

	for _, id in ipairs(order) do
		local def = Upgrades.ById and Upgrades.ById[id]
		local lvl = tonumber(levels[id]) or 0
		if def and lvl < (def.maxLevel or 0) then
			local okC, price = pcall(Upgrades.cost, id, lvl)
			if okC and type(price) == "number" and price <= spendable(d) then
				local done = false
				task.spawn(function()
					pcall(function() RF.BuyUpgrade:InvokeServer(id) end)
					done = true
				end)
				local t = 0
				while not done and t < 5 do task.wait(0.1); t = t + 0.1 end
				-- The profile push lags the purchase. One read after 0.4s missed
				-- a moveSpeed buy that did land, the finish read that as "nothing
				-- left to buy" and stopped with equip/luck at 0 for 10K-250K
				-- against 1.6e23 cash. Poll for the new level instead.
				local nl = lvl
				local w0 = os.clock()
				repeat
					task.wait(0.2)
					local after = data(true)
					nl = after and tonumber((after.upgrades or {})[id]) or lvl
				until nl > lvl or os.clock() - w0 > 3
				if nl > lvl then
					STATE.spent = STATE.spent + price
					note("upgrade " .. id .. " -> " .. nl)
					return   -- one per pass, so the balance is re-read every time
				end
			end
		end
	end
end

-- Two families: `sword*` carries a `winsCost` and `knife*` a `price`. Both read
-- the same Cash balance, so the only thing that matters is which field the entry
-- actually carries.
--
-- THE LADDER IS CLIMBED RUNG BY RUNG. The first build asked for the best
-- affordable axe, and with a large balance that is the top of the list - the
-- server answered nothing at all and the account sat on `sword1` for the whole
-- session while the cash was plainly there. The shop only hands over the next
-- rung, exactly like the gear ladder in `looksclick`, so this takes the CHEAPEST
-- unowned entry that still beats what is worn and repeats until a pass buys
-- nothing.
local function axeCost(a)
	if type(a.price) == "number" and a.price > 0 then return a.price end
	if type(a.winsCost) == "number" and a.winsCost > 0 then return a.winsCost end
	if type(a.price) == "number" or type(a.winsCost) == "number" then return 0 end
	return nil
end

local function axePass()
	if not (R.BuyAxe and Axes and Axes.Axes) then return end

	for _ = 1, 12 do
		local d = data()
		if not d then return end
		local owned = {}
		for _, v in pairs(d.owned or {}) do owned[tostring(v)] = true end

		local have = 0
		for _, a in ipairs(Axes.Axes) do
			if owned[a.id] and (a.multi or 0) > have then have = a.multi end
		end

		local pick = nil
		for _, a in ipairs(Axes.Axes) do
			local cost = axeCost(a)
			if not owned[a.id] and cost and (a.multi or 0) > have and cost <= spendable(d) then
				if (not pick) or cost < pick._cost then pick = a; pick._cost = cost end
			end
		end

		if not pick then
			-- Nothing left to buy: make sure the best one OWNED is the one worn.
			local wear, wm = nil, -1
			for _, a in ipairs(Axes.Axes) do
				if owned[a.id] and (a.multi or 0) > wm then wear, wm = a, a.multi end
			end
			if wear and d.equipped ~= wear.id and R.EquipAxe then
				pcall(function() R.EquipAxe:FireServer(wear.id) end)
			end
			return
		end

		pcall(function() R.BuyAxe:FireServer(pick.id) end)
		task.wait(0.7)
		local after = data(true)
		local got = false
		for _, v in pairs((after and after.owned) or {}) do
			if tostring(v) == pick.id then got = true break end
		end
		if not got then
			-- The rung was refused. Stop rather than hammering it - a repeated
			-- refusal here prints across the middle of the player's screen.
			note("axe " .. pick.id .. " refused")
			return
		end
		if R.EquipAxe then pcall(function() R.EquipAxe:FireServer(pick.id) end) end
		STATE.spent = STATE.spent + (pick._cost or 0)
		note("axe " .. tostring(pick.name) .. " x" .. tostring(pick.multi))
		task.wait(0.35)
	end
end

--------------------------------------------------------------------------------
-- pets
--------------------------------------------------------------------------------
--
-- `maxEquipped` is `1 + upgrades.equip` (the client's own formula; the +4 branch
-- is the gamepass and is never ours), and an egg that cannot be paid for answers
-- "broke" rather than erroring. So the best egg is FOUND by walking down from the
-- deepest one until the server stops refusing, and never from a price table alone.
-- Anything named RobuxEgg* is the paid twin and is skipped.
--
-- EGGS ARE PAID IN WOOD, not in cash - the client's own refusal text is "Not
-- Enough Wood!", which is the only reason the wood half of this game matters at
-- all. The costs below come out of the client's egg table and are used only to
-- decide how long to mint for; the server's answer is still what decides.
local EGG_COST = {
	Egg1 = 250, Egg2 = 25000, Egg4 = 50000, Egg3 = 2500000,
	Egg8 = 125000000, Egg5 = 1250000000, Egg6 = 1e10, Egg7 = 1.5e10,
	Egg9 = 5e13, Egg10 = 7.5e13, Egg11 = 1.25e16, Egg12 = 2.5e17,
	Egg13 = 3.75e17, Egg14 = 6.25e19, Egg15 = 1.25e21,
}

local bestEgg = nil

local function petPass()
	if not (RF.HatchEgg and R.PetAction) then return end
	local d = data()
	if not d then return end

	-- hatch
	-- The ladder is the folders in ReplicatedStorage PLUS the cost table: Egg1
	-- has no folder there (12 of 15 replicate), yet HatchEgg("Egg1") hatches a
	-- Cow for 250 wood - a fresh save sat on "no affordable egg" with 1,590
	-- wood because the one egg it could pay for was never on the list.
	local eggs, seen = {}, {}
	for _, inst in ipairs(ReplicatedStorage:GetChildren()) do
		local n = inst.Name:match("^Egg(%d+)$")
		if n and not seen[inst.Name] then
			seen[inst.Name] = true
			eggs[#eggs + 1] = { name = inst.Name, n = tonumber(n) }
		end
	end
	for name in pairs(EGG_COST) do
		if not seen[name] then
			seen[name] = true
			eggs[#eggs + 1] = { name = name, n = tonumber(name:match("%d+")) }
		end
	end
	table.sort(eggs, function(a, b) return a.n > b.n end)

	-- The known-good egg goes first, so a steady state costs exactly one call. On
	-- the first pass the ladder is WALKED DOWN from the deepest until the server
	-- stops answering "broke" - Egg15 and Egg12 refuse even on a very large
	-- balance, and a version of this that only tried the four deepest hatched
	-- nothing at all while looking perfectly healthy.
	local queue = {}
	if bestEgg then queue[#queue + 1] = { name = bestEgg } end
	for _, e in ipairs(eggs) do
		if e.name ~= bestEgg then queue[#queue + 1] = e end
	end

	local hatched, full = false, false
	for _, e in ipairs(queue) do
		local done, res = false, nil
		task.spawn(function()
			local ok, r = pcall(function() return RF.HatchEgg:InvokeServer(e.name) end)
			res = ok and r or nil
			done = true
		end)
		local t = 0
		while not done and t < 4 do task.wait(0.1); t = t + 0.1 end
		if res == "full" then
			note("pet storage full")
			full = true
			break
		elseif res and res ~= "broke" then
			if bestEgg ~= e.name then bestEgg = e.name end
			note("hatched " .. tostring(res) .. " from " .. e.name)
			hatched = true
			-- Once the rung is known, take it in threes: HatchEggBatch is the
			-- game's own "hatch 3" button and costs exactly 3x the single price.
			if RF.HatchEggBatch then
				for _ = 1, math.max(0, CONFIG.petBatches) do
					local bd, br = false, nil
					task.spawn(function()
						local bok, r = pcall(function()
							return RF.HatchEggBatch:InvokeServer(e.name, 3)
						end)
						br = bok and r or nil
						bd = true
					end)
					local bt = 0
					while not bd and bt < 5 do task.wait(0.1); bt = bt + 0.1 end
					if type(br) ~= "table" then break end
					task.wait(0.2)
				end
			end
			break
		elseif res == "broke" and bestEgg == e.name then
			-- what used to be affordable no longer is (a rebirth, a big
			-- purchase): forget it and let the walk find the new rung.
			bestEgg = nil
		end
	end
	-- "full" is its own answer; reporting it as "no affordable egg" sent the
	-- reader looking at the wood balance (6.6e9 of it) instead of the storage
	if not hatched and not full and not bestEgg then note("no affordable egg") end

	-- WEAR THE BEST, NOT THE FIRST. This used to toggle_equip pets 1..N by
	-- index, which wore whatever was hatched first - a player reported "it
	-- doesn't equip best pets" and that was exactly it. The pets menu
	-- (PlayerScripts.Client.PetsMenu) has an "Equip Best" button that fires
	-- PetAction("equip_best", nil); the game ranks, we just press it.
	pcall(function() R.PetAction:FireServer("equip_best", nil) end)
	task.wait(0.6)

	-- A FULL STORAGE STOPPED THE WHOLE PET LADDER. HatchEgg answers "full" at
	-- 30 pets (30 + 30 x storage upgrade) and nothing here ever made room, so
	-- the account sat on 30 early pets with 6.6e9 wood unspent. Only worn pets
	-- pay, and Equip Best has just picked those, so everything not worn goes
	-- through the menu's own Delete: PetAction("delete", {indices}).
	if full then
		local e = data(true)
		if not e then return end
		local worn = {}
		for _, v in pairs(e.equippedPets or {}) do worn[tonumber(v) or -1] = true end
		local drop = {}
		for i = 1, count(e.pets) do
			if not worn[i] then drop[#drop + 1] = i end
		end
		if #drop > 0 and count(e.equippedPets) > 0 then
			pcall(function() R.PetAction:FireServer("delete", drop) end)
			task.wait(0.6)
			local after = data(true)
			note(("storage full - deleted %d unworn pets (%d -> %d)"):format(
				#drop, count(e.pets), count(after and after.pets)))
		end
	end
end

--------------------------------------------------------------------------------
-- rebirth and the free things
--------------------------------------------------------------------------------

-- The gate is the LEVEL, exactly as the menu states it. What a rebirth actually
-- COSTS is not what the menu says: its warning reads "Rebirthing resets Strength!"
-- and the measurement is wider than that - Strength, the LEVEL (203 -> 1) and
-- EVERY AXE (11 owned -> back to sword1 alone). Cash, wood, the chopper, the pets
-- and all six upgrades survive untouched.
--
-- So the axe ladder has to be climbed again afterwards, and on a thin balance that
-- is the whole income thrown away for a multiplier. The guard below only rebirths
-- when the cash on hand covers re-buying what is worn several times over; with a
-- developed balance that is always true and the rebirth fires freely.
local function axeReplaceCost(d)
	if not (Axes and Axes.Axes) then return 0 end
	local worn = d and d.equipped
	for _, a in ipairs(Axes.Axes) do
		if a.id == worn then return axeCost(a) or 0 end
	end
	return 0
end

-- The requirement is NOT a constant: `rebirthLevelRequirement(n)` is 25 + 25n, so
-- it was 25 on a fresh account and 125 at four rebirths. A hardcoded 25 reads as
-- "always ready" and the call is then refused forever, which looks exactly like a
-- dead remote. The game's own function is asked instead, and the panel shows it.
local function rebirthNeed(d)
	local n = tonumber(d and d.rebirths) or 0
	if Levels and Levels.rebirthLevelRequirement then
		local ok, v = pcall(Levels.rebirthLevelRequirement, n)
		if ok and type(v) == "number" then return v end
	end
	return 25 + 25 * n
end

local function rebirthPass()
	if not RF.RebirthFunc then return end

	-- The level resets to 1 on every rebirth, so at most one can land per climb -
	-- but the loop is here because with the TURBO page running the level comes
	-- back between two passes and a once-per-call check simply misses them.
	for _ = 1, 5 do
		local d = data()
		if not d then return end
		local need = rebirthNeed(d)
		STATE.rebirthNeed = need
		if (tonumber(d.level) or 0) < need then return end

		local replace = axeReplaceCost(d)
		if replace > 0 and (tonumber(d.cash) or 0) < replace * CONFIG.rebirthAxeReserve then
			note("rebirth held: axe ladder not re-buyable")
			return
		end

		local done, res = false, nil
		task.spawn(function()
			local ok, r = pcall(function() return RF.RebirthFunc:InvokeServer() end)
			res = ok and r or nil
			done = true
		end)
		local t = 0
		while not done and t < 6 do task.wait(0.1); t = t + 0.1 end
		if res ~= "ok" then return end
		note("rebirth " .. tostring((d.rebirths or 0) + 1))
		chopped = {}
		task.wait(0.8)
	end
end

local FREEBIES_DONE = false

local function freebiePass()
	if FREEBIES_DONE then return end
	FREEBIES_DONE = true
	local function fire(rf, ...)
		if not rf then return end
		local args = table.pack(...)
		local done = false
		task.spawn(function()
			pcall(function() return rf:InvokeServer(table.unpack(args, 1, args.n)) end)
			done = true
		end)
		local t = 0
		while not done and t < 6 do task.wait(0.1); t = t + 0.1 end
	end
	-- The one code that ships enabled in the client's own QuestsData.
	fire(RF.RedeemCode, "hamburger")
	fire(RF.ClaimOfflineEarnings)
	fire(RF.DailyClaimFunc)
	fire(RF.GroupRewardClaim)
	local d = data()
	for _ = 1, math.min(tonumber(d and d.spins) or 0, 10) do
		fire(RF.SpinAura)
		task.wait(0.4)
	end
	note("freebies claimed")
end

--------------------------------------------------------------------------------
-- TURBO - the client-authority hole, off by default
--------------------------------------------------------------------------------
--
-- `ChopTreeHit` takes an array of ZONE NUMBERS and the server validates neither
-- the zone nor the position - only the count, which it caps at 13. A call of 13
-- entries at zone 52 pays 13 x 483,000,000 wood and rolls 13 drops at that zone's
-- treasure tier, which is where the cash is. It still needs an ACTIVE RUN.
--
-- This is real, server-side progress and it is also an obvious dupe, so it lives
-- on its own page, defaults off and is in no preset.

local function turboFire()
	if not R.ChopTreeHit then return false end
	if not runActive() then
		if not enterRun() then return false end
	end
	local z = math.clamp(math.floor(CONFIG.turboZone), 1, 52)
	local n = math.clamp(math.floor(CONFIG.turboPerCall), 1, 13)
	local arr = {}
	for i = 1, n do arr[i] = z end
	pcall(function() R.ChopTreeHit:FireServer(arr, nextSeq()) end)
	STATE.turboCalls = STATE.turboCalls + 1
	return true
end

local function turboPass()
	if not CONFIG.turbo then return end
	if not turboFire() then note("turbo: no run") end
end

-- Mint wood until the next egg UP the ladder is affordable, then let petPass take
-- it. Measured throughput, claiming 13 trees at zone 52: a 0.3s gap credits 100%
-- of the calls at 21.4 bn wood/s, 0.1s credits 56% at 31.4 bn/s and 0.03s credits
-- 27% at 42.7 bn/s - so firing harder still wins, it just wastes calls.
--
-- What that buys, honestly: Egg9 costs 50 trillion and Egg10 75 trillion, which is
-- twenty to thirty minutes of minting. Egg11 is 1.25e16 and Egg15 1.25e21 - days
-- and then centuries - because `woodForZone` CLAMPS at zone 52 (483,000,000 per
-- tree) and does not extrapolate, so there is no bigger claim to make. The push
-- therefore aims at the best egg it can actually reach and says so.
local function petPushPass()
	if not (CONFIG.petPush and RF.HatchEgg) then return end
	local d = data(true)
	if not d then return end
	local wood = tonumber(d.wood) or 0

	local target, targetCost = nil, nil
	for name, cost in pairs(EGG_COST) do
		if cost > wood and (not targetCost or cost < targetCost) then
			if cost <= CONFIG.petPushCeiling then target, targetCost = name, cost end
		end
	end
	if not target then return end

	STATE.finishStep = "minting for " .. target
	local t0 = os.clock()
	while os.clock() - t0 < CONFIG.petPushSecs and GEN == _G.__CHOPTREES do
		if not turboFire() then break end
		task.wait(0.1)
		if os.clock() - t0 > 3 then
			local now = data()
			if (tonumber(now and now.wood) or 0) >= targetCost then break end
		end
	end
	note("minted for " .. target)
end

-- THE REBIRTH RUSH. A rebirth needs `25 + 25n` levels and wipes the level back to
-- 1, so the pace of the whole prestige ladder is simply how fast XP comes in. The
-- same call the wood comes from pays it: one claim of 13 zone-52 trees measured
-- **122 billion cumulative XP**, so the climb back to the requirement is seconds
-- rather than the minutes a training pad needs.
--
-- The cumulative figure is what is watched, never `xp` on its own: that field is
-- XP WITHIN the current level and resets on every level-up, so a rush measured
-- against it reads as going backwards.
local function cumulativeXp(d)
	if not (d and Levels and Levels.cumulativeXpToLevel) then return 0 end
	local ok, v = pcall(Levels.cumulativeXpToLevel, tonumber(d.level) or 1)
	return (ok and tonumber(v) or 0) + (tonumber(d.xp) or 0)
end

local function rebirthRushPass()
	if not (R.ChopTreeHit and RF.RebirthFunc) then return end
	local start = data(true)
	local from = tonumber(start and start.rebirths) or 0

	-- No "is the farm running" guard here: this is also the panel's own button, and
	-- the first version broke out on its first iteration whenever it was pressed by
	-- hand, because neither `auto` nor `rebirthRush` is set in that case. The
	-- generation check is the stop, exactly like every other loop in this file.
	for i = 1, math.max(1, CONFIG.rebirthRushCount) do
		if GEN ~= _G.__CHOPTREES then break end
		local d = data()
		if not d then break end
		local need = rebirthNeed(d)
		STATE.rebirthNeed = need
		STATE.finishStep = string.format("rush %d/%d (lv %s/%s)",
			i, CONFIG.rebirthRushCount, tostring(d.level), tostring(need))

		-- climb to the requirement on the hole itself
		local t0 = os.clock()
		while (tonumber(data() and data().level) or 0) < need
			and os.clock() - t0 < CONFIG.rebirthRushSecs
			and GEN == _G.__CHOPTREES do
			if not turboFire() then break end
			task.wait(CONFIG.turboGap)
		end

		local before = tonumber(data(true) and data(true).rebirths) or 0
		rebirthPass()
		local after = tonumber(data(true) and data(true).rebirths) or before
		if after <= before then
			note("rush stalled at level " .. tostring(data() and data().level))
			break
		end
		STATE.rushed = (STATE.rushed or 0) + (after - before)
	end

	local e = data(true)
	note(string.format("rush: rebirths %d -> %s", from, tostring(e and e.rebirths)))
end

--------------------------------------------------------------------------------
-- FINISH - one pass that takes the account as far as the game goes
--------------------------------------------------------------------------------
--
-- The whole game in one sweep, off the same hole: claim deep-zone trees, take the
-- treasure they drop, sell it, then spend the proceeds on every ladder at once and
-- rebirth as far as the level carries. It is the TURBO page's reason for existing
-- rather than a second feature - everything below is a call already measured above.

-- ONE BODY. The button used to task.spawn this straight next to the running
-- farm: training walked the body to the pad while the finish walked it to the
-- run, the farm's end-of-pass cleared STATE.busy under the finish, and the
-- user had to press it again and again before everything was bought. Now
-- FINISHING pauses every other loop, the train/chop loops step out mid-pass,
-- and the finish waits for the body thread to report idle before it moves.
local function finishPass()
	if FINISHING then return end
	FINISHING = true
	STATE.busy = true
	STATE.finishStep = "pausing the farm"
	local w0 = os.clock()
	while BODY_ACTIVE and os.clock() - w0 < 15 do task.wait(0.1) end
	local ok, err = pcall(function()
		local d = data(true)
		local startCash = (d and d.cash) or 0

		-- 1. treasure: fire, loot up to the bag, bank, sell. Repeated because the
		--    bag is the limit per trip, not the drop rate.
		for trip = 1, math.max(1, CONFIG.finishTrips) do
			STATE.finishStep = string.format("trip %d/%d", trip, CONFIG.finishTrips)
			if not runActive() then
				if not enterRun() then break end
			end
			local cap = carryMax(data())
			for _ = 1, cap + 2 do
				if not CONFIG.auto and not FINISHING then break end
				turboFire()
				task.wait(CONFIG.turboGap)
				lootPass()
				local now = data()
				if count(now and now.treasureCarried) >= carryMax(now) then break end
			end
			bankPass()
			sellPass()
		end

		-- 2. REBIRTH BEFORE BUYING. A rebirth wipes every axe, so a sweep that
		--    climbed the ladder first and rebirthed afterwards threw the whole
		--    ladder away every single pass - measured, 11 axes back down to
		--    `sword1` one step after they were bought. Prestige first, then spend,
		--    and the ladder that gets bought is the one that is kept.
		STATE.finishStep = "rebirth"
		if CONFIG.rebirthRush then pcall(rebirthRushPass) else pcall(rebirthPass) end

		-- 3. spend it, best first, and let every ladder run to a standstill.
		--    ONE CLICK HAS TO FINISH IT. The six upgrades hold 133 levels
		--    between them (3 x 33, equip 4, luck 12, backpack 18) and the old
		--    loop stopped after 30 buys, so the user had to press the button
		--    again and again. Now it repeats chopper + axe + upgrade rounds
		--    until a whole round buys nothing - measured on STATE.spent, since a
		--    note can repeat word for word.
		STATE.finishStep = "buying"
		local idle = 0
		for round = 1, 250 do
			if GEN ~= _G.__CHOPTREES then break end
			local before = STATE.spent
			pcall(chopperPass)
			pcall(axePass)
			-- upgrades back to back: re-running the chopper and axe checks
			-- between every single level made each one cost ~3s
			for _ = 1, 150 do
				local b = STATE.spent
				pcall(upgradePass)
				STATE.finishStep = string.format("buying (%d)", round)
				if STATE.spent == b then break end
			end
			-- three empty rounds in a row, so a missed confirmation (luck was
			-- the slow one) cannot end it
			if STATE.spent == before then idle = idle + 1 else idle = 0 end
			if idle >= 3 then break end
		end
		-- eggs are priced in WOOD, so the pet ladder needs its own mint
		pcall(petPushPass)
		pcall(petPass)
		pcall(petPass)

		local e = data(true)
		STATE.finishStep = "done"
		note(string.format("finish: cash %s -> %s, rebirths %s",
			tostring(startCash), tostring(e and e.cash), tostring(e and e.rebirths)))
	end)
	if not ok then note("finish failed: " .. tostring(err)) end
	STATE.busy = false
	FINISHING = false
end

--------------------------------------------------------------------------------
-- worlds
--------------------------------------------------------------------------------
--
-- Four worlds behind a LEVEL gate, the numbers straight out of the client's own
-- `PlayerLevels`: Candyland 200, Frost 400, Cyber 600. `UnlockZone(name)` buys the
-- unlock and `TeleportToZone(name)` travels; the profile mirrors the result in
-- `zone2Unlocked` .. `zone5Unlocked`.
--
-- Worth knowing before hoping for the deep ones: the XP curve is what stops this,
-- not the gate. `cumulativeXpToLevel` is 2.2e11 at level 225, 5.95e13 at 275 and
-- **7.2e19 at 400** - so at the ~6.8e11 XP/s the hole actually produces, Candyland
-- is immediate, Frost is years away and Cyber is not a number worth writing down.
-- The same curve caps the rebirth ladder at about eleven.
local WORLD_LEVEL = { Zone2 = 200, Zone3 = 400, Zone4 = 600 }

local function worldPass()
	if not RF.UnlockZone then return end
	local d = data()
	if not d then return end
	local level = tonumber(d.level) or 0

	for _, name in ipairs({ "Zone2", "Zone3", "Zone4" }) do
		local need = WORLD_LEVEL[name]
		local flagName = name:gsub("Zone", "zone") .. "Unlocked"
		if not d[flagName] then
			if level >= need then
				local done = false
				task.spawn(function()
					pcall(function() RF.UnlockZone:InvokeServer(name) end)
					done = true
				end)
				local t = 0
				while not done and t < 6 do task.wait(0.1); t = t + 0.1 end
				task.wait(0.8)
				local after = data(true)
				if after and after[flagName] then
					note("unlocked " .. name)
					STATE.worldsOpen = (STATE.worldsOpen or 0) + 1
				end
			end
			return   -- one at a time, in order
		end
	end
end

-- Travel to the deepest world that is unlocked, because the better train pads and
-- the deeper chop zones live there. The travel call is the same one `goHome` uses.
local function worldTravelPass()
	if not (CONFIG.worlds and RF.TeleportToZone) then return end
	local d = data()
	if not d then return end
	local want = "Zone1"
	for _, name in ipairs({ "Zone2", "Zone3", "Zone4" }) do
		local flagName = name:gsub("Zone", "zone") .. "Unlocked"
		if d[flagName] then want = name end
	end
	local area = currentArea()
	if area and area.Name == want then return end
	if want == "Zone1" then return end
	local done = false
	task.spawn(function()
		pcall(function() RF.TeleportToZone:InvokeServer(want) end)
		done = true
	end)
	local t = 0
	while not done and t < 6 do task.wait(0.1); t = t + 0.1 end
	task.wait(1.5)
	note("travelled to " .. want)
end

--------------------------------------------------------------------------------
-- refresh
--------------------------------------------------------------------------------

local function refresh()
	local d = data()
	if not d then return end
	STATE.strength = tonumber(d.strength) or 0
	STATE.cash = tonumber(d.cash) or 0
	STATE.wood = tonumber(d.wood) or 0
	STATE.level = tonumber(d.level) or 0
	STATE.xp = tonumber(d.xp) or 0
	STATE.xpNeed = tonumber(d.xpNeed) or 0
	STATE.rebirths = tonumber(d.rebirths) or 0
	STATE.chopper = tostring(d.equippedChopper or "-")
	STATE.chopperBonus = tonumber(d.chopperBonus) or 1
	STATE.axe = tostring(d.equipped or "-")
	STATE.carried = count(d.treasureCarried)
	STATE.carryMax = carryMax(d)
	STATE.stock = count(d.treasureStock)
	STATE.pets = count(d.pets)
	STATE.petsWorn = count(d.equippedPets)
	STATE.petSlots = 1 + (tonumber((d.upgrades or {}).equip) or 0)
	STATE.totalMulti = tonumber(d.totalMulti) or 1
	local area = currentArea()
	STATE.zone = area and area.Name or "-"
	STATE.runActive = runActive()
end

--------------------------------------------------------------------------------
-- debug handle, published BEFORE the panel is built
--------------------------------------------------------------------------------
--
-- With this assigned at the end of the file, anything that yields in the UI means
-- the handle is never published and the script looks like it failed to load.

_G.__CHOPTREES_DBG = {
	CONFIG = CONFIG, STATE = STATE, PADS = PADS,
	data = data, refresh = refresh, unstuck = unstuck,
	trainPass = trainPass, chopPass = chopPass, enterRun = enterRun,
	lootPass = lootPass, bankPass = bankPass, sellPass = sellPass,
	chopperPass = chopperPass, upgradePass = upgradePass, axePass = axePass,
	petPass = petPass,
	rebirthPass = rebirthPass, freebiePass = freebiePass, turboPass = turboPass,
	finishPass = finishPass, turboFire = turboFire, petPushPass = petPushPass,
	rebirthRushPass = rebirthRushPass, rebirthNeed = rebirthNeed,
	worldPass = worldPass, worldTravelPass = worldTravelPass,
	treesInReach = treesInReach, runActive = runActive, bestPad = bestPad,
}

--------------------------------------------------------------------------------
-- loops
--------------------------------------------------------------------------------

local function loop(sec, key, fn, needsBody)
	task.spawn(function()
		while GEN == _G.__CHOPTREES do
			if CONFIG.auto and (key == nil or CONFIG[key]) and not (needsBody and STATE.busy)
				and not FINISHING then
				local ok, err = pcall(fn)
				if not ok then note(tostring(key) .. " failed: " .. tostring(err)) end
			end
			task.wait(sec)
		end
	end)
end

-- Live read-out, whether the farm runs or not.
task.spawn(function()
	local lastS, lastC, lastT = nil, nil, os.clock()
	while GEN == _G.__CHOPTREES do
		pcall(refresh)
		local now = os.clock()
		local dt = now - lastT
		if dt >= 4 then
			if lastS then STATE.strengthRate = math.max(0, (STATE.strength - lastS) / dt) end
			if lastC then STATE.cashRate = math.max(0, (STATE.cash - lastC) / dt) end
			lastS, lastC, lastT = STATE.strength, STATE.cash, now
		end
		task.wait(1)
	end
end)

-- One body, one owner. Training, the run and the market trip pull in opposite
-- directions, so they run back to back in one thread instead of fighting.
-- BODY_ACTIVE says this thread is mid-pass; "Run it once" waits for it.
task.spawn(function()
	while GEN == _G.__CHOPTREES do
		if FINISHING then
			-- "Run it once" owns the body; stand aside until it is done
			BODY_ACTIVE = false
		elseif CONFIG.auto and CONFIG.finishLoop then
			if CONFIG.freebies then pcall(freebiePass) end
			pcall(finishPass)
			task.wait(1)
		elseif CONFIG.auto and (CONFIG.train or CONFIG.chop or CONFIG.treasure or CONFIG.turbo) then
			BODY_ACTIVE = true
			STATE.busy = true

			if CONFIG.freebies then pcall(freebiePass) end

			if CONFIG.train then pcall(function() trainPass(CONFIG.trainSecs) end) end

			if CONFIG.turbo then
				STATE.phase = "turbo"
				local t0 = os.clock()
				while os.clock() - t0 < CONFIG.chopSecs and CONFIG.auto and CONFIG.turbo
					and GEN == _G.__CHOPTREES and not FINISHING do
					pcall(turboPass)
					if CONFIG.treasure then pcall(lootPass) end
					task.wait(CONFIG.turboGap)
				end
			elseif CONFIG.chop then
				pcall(function() chopPass(CONFIG.chopSecs) end)
			end

			if CONFIG.treasure and not FINISHING then
				pcall(lootPass)
				pcall(bankPass)
				pcall(sellPass)
			end

			BODY_ACTIVE = false
			-- never clear the flag out from under a running "Run it once"
			if not FINISHING then
				STATE.busy = false
				STATE.phase = "idle"
			end
		end
		task.wait(1)
	end
end)

loop(12, "spend", function() chopperPass() end)
loop(9,  "spend", function() upgradePass() end)
loop(15, "spend", function() axePass() end)
loop(11, "pets",  function() petPass() end)
loop(20, "rebirth", function() rebirthPass() end)
loop(17, "worlds", function() worldPass() end)

--------------------------------------------------------------------------------
-- panel
--------------------------------------------------------------------------------

local UI = (_G.__SEL and _G.__SEL.ui) or loadstring(readfile("ui-template.lua"))()

-- UI.sweep pcalls each container on its own; a hand written list has a nil hole
-- that stops ipairs, and on some executors CoreGui THROWS rather than returning.
if UI.sweep then pcall(function() UI.sweep("ChopTreesPanel") end) end

UI.config("choptrees", CONFIG)

local win = UI.Window({
	name = "ChopTreesPanel",
	title = "CHOP",
	accentTitle = "TREES",
	subtitle = "seltonmt",
})

local function short(n)
	n = tonumber(n) or 0
	local units = { "", "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", "Dc" }
	local i = 1
	while math.abs(n) >= 1000 and i < #units do n = n / 1000; i = i + 1 end
	if i > #units - 1 then return string.format("%.2e", tonumber(n) or 0) end
	return string.format("%.2f", n):gsub("%.?0+$", "") .. units[i]
end

local farm = win:Page("FARM", UI.icon.bolt)

local loopCard = farm:Card("LOOP", 1):Accent()
loopCard:Toggle("Train", CONFIG.train, function(v) CONFIG.train = v end,
	"Stands on the best pad the rebirth count allows. The server credits about 3 hits per second and no more.")
loopCard:Slider("Training seconds", 5, 90, CONFIG.trainSecs, function(v) CONFIG.trainSecs = v end)
loopCard:Toggle("Chop", CONFIG.chop, function(v) CONFIG.chop = v end,
	"Opens a run and reports the trees the current Strength really fells.")
loopCard:Slider("Chopping seconds", 10, 120, CONFIG.chopSecs, function(v) CONFIG.chopSecs = v end)
loopCard:Toggle("Treasure", CONFIG.treasure, function(v) CONFIG.treasure = v end,
	"Loot the drops, carry them home, sell the stock at the market.")

local spendCard = farm:Card("SPENDING", 2)
spendCard:Toggle("Buy", CONFIG.spend, function(v) CONFIG.spend = v end,
	"Chopper first - it multiplies every strength tick - then upgrades, then axes.")
spendCard:Toggle("Backpack first", CONFIG.backpackFirst, function(v) CONFIG.backpackFirst = v end,
	"Carry slots decide how much treasure a run brings home, and treasure is the only real income.")
spendCard:Toggle("Pets", CONFIG.pets, function(v) CONFIG.pets = v end,
	"Hatches the deepest egg the balance covers and wears the best ones. Robux eggs are skipped.")
spendCard:Toggle("Rebirth", CONFIG.rebirth, function(v) CONFIG.rebirth = v end,
	"Fires as soon as the game's own requirement is met. It also wipes every axe, so it waits until the cash can re-buy them.", UI.theme.warn)
spendCard:Toggle("Worlds", CONFIG.worlds, function(v) CONFIG.worlds = v end,
	"Unlocks Candyland at level 200. Frost wants 400 and Cyber 600, and the XP curve puts those years away - the panel says so rather than pretending.")
spendCard:Toggle("Free rewards", CONFIG.freebies, function(v) CONFIG.freebies = v end,
	"Code, daily, offline earnings, group, banked aura spins - once per run of the script.")

local manual = farm:Card("MANUAL", 1)
manual:Button("Enter run", function() task.spawn(enterRun) end)
manual:Button("Sell stock", function() task.spawn(sellPass) end)
manual:Button("Unstuck", function() unstuck() end, UI.theme.bad)

local out = farm:Card("STATUS", 0):Readout(13)

local turboPage = win:Page("TURBO", UI.icon.flame)
local tCard = turboPage:Card("CLIENT AUTHORITY", 0):Accent()
tCard:Label("The server takes the tree list from the client and checks neither the zone nor where you stand. Measured on this place:")
tCard:Label("1 / 5 / 13 entries  ->  1 / 5 / 13 credited")
tCard:Label("20 / 50 / 1000 entries  ->  13 credited, every time")
tCard:Label("zone 52 claimed from zone 1  ->  483,000,000 wood")
tCard:Label("its drop  ->  Nexus Heart, 7.6e21 cash (zone 1 pays 11)")
tCard:Label("It still needs an ACTIVE RUN - outside one nothing credits at all.")
tCard:Toggle("Turbo", CONFIG.turbo, function(v) CONFIG.turbo = v end,
	"Replaces the honest chop pass while it is on.", UI.theme.bad)
tCard:Slider("Zone claimed", 1, 52, CONFIG.turboZone, function(v) CONFIG.turboZone = v end)
tCard:Slider("Entries per call", 1, 13, CONFIG.turboPerCall, function(v) CONFIG.turboPerCall = v end)

local fCard = turboPage:Card("FINISH THE ACCOUNT", 0)
fCard:Label("One sweep: claim deep-zone trees, take the treasure they drop, sell it, then spend the lot on the chopper, the axe ladder, every upgrade and the pets, and rebirth as far as the level carries.")
fCard:Button("Run it once", function() task.spawn(finishPass) end, UI.theme.bad)
fCard:Toggle("Keep sweeping", CONFIG.finishLoop, function(v) CONFIG.finishLoop = v end,
	"Repeats the sweep instead of running once. Needs the master switch on.", UI.theme.bad)
fCard:Slider("Market trips per sweep", 1, 10, CONFIG.finishTrips, function(v) CONFIG.finishTrips = v end)
fCard:Toggle("Mint wood for pets", CONFIG.petPush, function(v) CONFIG.petPush = v end,
	"Eggs are priced in WOOD. Measured: 21.4 bn/s at a 0.3s gap, 42.7 bn/s flat out. That reaches Egg9 and Egg10 in twenty to thirty minutes; Egg11 upwards is out of reach because the wood curve clamps at zone 52.", UI.theme.bad)
fCard:Slider("Minting seconds", 15, 300, CONFIG.petPushSecs, function(v) CONFIG.petPushSecs = v end)

local rCard = turboPage:Card("REBIRTH RUSH", 0)
rCard:Label("A rebirth needs 25 + 25n levels and puts the level back to 1, so the ladder moves at the speed XP comes in. One claim of 13 zone-52 trees measured 122 billion XP, which is seconds per rung instead of minutes.")
rCard:Button("Rush now", function() task.spawn(rebirthRushPass) end, UI.theme.bad)
rCard:Toggle("Rush inside the sweep", CONFIG.rebirthRush, function(v) CONFIG.rebirthRush = v end,
	"The FINISH sweep then rushes rebirths instead of taking a single one.", UI.theme.bad)
rCard:Slider("Rebirths per rush", 1, 40, CONFIG.rebirthRushCount, function(v) CONFIG.rebirthRushCount = v end)

task.spawn(function()
	while GEN == _G.__CHOPTREES do
		local ok = pcall(function()
			out:set({
				"STATE",
				string.format("  phase      %s%s   %s", STATE.phase,
					STATE.busy and " (busy)" or "", STATE.finishStep ~= "-" and ("finish: " .. STATE.finishStep) or ""),
				string.format("  rebirth    %d   next at level %d (now %d)",
					STATE.rebirths, STATE.rebirthNeed, STATE.level),
				string.format("  area       %s   run %s", STATE.zone, STATE.runActive and "open" or "closed"),
				string.format("  pad        %s  (reward %s)", STATE.pad, tostring(STATE.padReward)),
				"ECONOMY",
				string.format("  strength   %s   (%s/s)", short(STATE.strength), short(STATE.strengthRate)),
				string.format("  cash       %s   (%s/s)", short(STATE.cash), short(STATE.cashRate)),
				string.format("  wood       %s", short(STATE.wood)),
				string.format("  chopper    %s  x%s", STATE.chopper, short(STATE.chopperBonus)),
				string.format("  axe        %s   multi x%s", STATE.axe, short(STATE.totalMulti)),
				string.format("  pets       %d owned, %d/%d worn", STATE.pets, STATE.petsWorn, STATE.petSlots),
				string.format("  treasure   %d/%d carried, %d in stock", STATE.carried, STATE.carryMax, STATE.stock),
				"RUN",
				string.format("  runs %d   felled %d   looted %d   sold %d", STATE.runs, STATE.felled, STATE.looted, STATE.sold),
				STATE.note ~= "" and ("  " .. STATE.note) or "  -",
			})
			win:SetStatus(string.format("%s cash   %s strength   lv%d   %d rebirths",
				short(STATE.cash), short(STATE.strength), STATE.level, STATE.rebirths))
			win:SetStat(1, short(STATE.cash), "cash")
			win:SetStat(2, short(STATE.strength), "strength")
			win:SetStat(3, tostring(STATE.rebirths), "rebirths")
		end)
		if not ok then task.wait(2) end
		task.wait(1)
	end
end)

pcall(function()
	win:SetMaster(CONFIG.auto, "Auto Farm")
	win:OnMaster(function(on)
		CONFIG.auto = on
		note(on and "auto on" or "auto off")
	end)
end)

pcall(function() win:Home() end)

note("ready")
