--[[ cutgrass.lua - "+1 Cut Grass Adventure" (place 90086669327265)

  The loop the game actually runs:

      CLICK                 -> Strength   (argument-less, server cooldown 0.08s)
      stand on a TRAIN PAD  -> Strength   (+multiplier every 0.5s, and it STACKS
                                           with clicking - measured, see below)
      Strength IS the damage that cuts GRASS; every zone's grass has a fixed
      health, 50 in zone 1 up to 700 BILLION in zone 15
      behind the grass lies LOOT          -> carried in a 3-slot backpack
      loot is SOLD for Money              -> cutters (DamageMult), auras, upgrades
      Rebirth (level 25)                  -> multipliers and the next train pads
      five worlds, gated on the PLAYER LEVEL (185 / 380 / 570 / 750)

  ============================================================================
  READ THIS FIRST: THIS GAME HAS A REAL ANTI-CHEAT, AND IT IS A GOOD ONE
  ============================================================================

  `ReplicatedStorage.Shared.Configs.AntiCheat` is 200 lines of a properly built
  detection system with a ban DataStore, a suspect registry keyed by risk score
  and an admin tool that bulk-bans 100 accounts in one press. Three checks:

  * HONEYPOT - twenty decoy remotes, and ONE call is an immediate detect at
    risk 100. No accumulation, no grace. They sit in `DataService.RE` under
    exactly the names a farm script reaches for first: AddMoney, SetCash,
    GiveCoins, SetCurrency, ClaimMoney, ClaimAllRewards, SellAll,
    CollectAllLoot, RebirthAll, UpgradeAll, TrainAll and the rest. They do
    nothing except mark the account. Every remote this file fires was read out
    of the game's OWN controllers first (`Shared.Controllers.*`, all
    decompilable) so that only calls a real client makes are ever sent, and
    `fire()` below additionally refuses the whole list by name at runtime.

  * MOVEMENT - a 0.2s sample of speed and teleports, risk 70. A jump of 120
    studs or more is never excused by latency, sustained speed above about
    1.15x walkspeed over a 2s window is not either, and writing
    `Humanoid.WalkSpeed` is its own detection. **So this script never warps and
    never writes WalkSpeed.** Everything moves through `Humanoid:MoveTo`, which
    is the character walking at the speed the server issued it. Measured: base
    to zone 1 is 100 studs in 4.3s, 23 studs/s, entirely clean.

  * GRASSNOCLIP - walking through grass that is still standing for you, risk 80.
    The game puts a client-side blocker part (`_GD_GrassBlocker`) in front of
    uncut grass, and that blocker is the thing keeping this check quiet. This
    script leaves it alone. It is a guard, not an obstacle.

  As of the last read every check is `DetectionEnabled = true` with
  `PunishmentMode = "Warn"` and `EnforcementEnabled = false`, so a detection
  costs nothing TODAY - but it is written into `CutGrassAntiCheatSuspects_v3`
  with a risk score and that list is what the bulk-ban tool reads. Being
  recorded is a deferred bill, not a free pass.

  The server pushes `AntiCheatService.IncidentWarning` at the client it caught,
  so this panel listens for it: one warning switches AUTO off, stops every loop
  and prints what was detected. If that ever fires, something in here is wrong -
  read the note and say so, do not turn it back on.

  ============================================================================
  MEASURED, ALL AGAINST SERVER-SIDE VALUES
  ============================================================================

  * Idle gains nothing. 3s with no calls = 0 strength.

  * `StrengthService.ClickRequested:Fire()` takes no arguments. 1047 calls in 6s
    credited 70 strength = 11.66/s, which is `Strength.ClickCooldownSeconds`
    0.08 almost exactly. **12.5/s is the entire budget** and one call per frame
    wastes 93% of them, so this file paces the click at 0.075s instead of
    hammering it - flooding a remote is also what silently queued every other
    call in Training To Climb for four minutes.

  * Training pads and clicking STACK, which is the opposite of heroevo. Measured
    on the free x1.5 pad: pad alone 2.75 strength/s (11 pulses of 1.5 in 6s, the
    0.5s TickSeconds), clicking alone 11.66/s, both together 13.37/s. So the
    body belongs on a pad whenever it is not cutting, and the click loop never
    stops. Free pads are gated on the rebirth count (x1.5 at 0, x2 at 2, x4 at
    5, x6 at 8 ... x45 at 36); every pad carrying a `GamepassId` (x10, x25,
    x100, x300, x1000) is skipped on the FIELD, never on the name.

  * `AttackService.AttackRequested:Fire()` takes no arguments either - the
    server sweeps around your own position, `Attack.PlayerCoverageRadius` 6 plus
    a forward sweep of up to 10 studs. The cooldown is a hard 0.5s: fired at
    0.25s intervals exactly every second call came back
    `AttackPerformed(false, 0)`.

  * Grass health is the whole gate, and it is a table:
    `Zone.GrassHealthByIndex` = 50, 500, 3000, 15000, 60000, 300000, 1.49M,
    8.36M, 46M, 248M, 1.32B, 6.99B, 36.5B, 90B, 700B ... over 57 zones.
    Measured in zone 1 at strength 476: one blade per hit, 13 blades in 14
    attacks while walking. Measured in zone 2 (500 HP) at strength 120: 34
    accepted attacks, 3 blades. The zone picker below does NOT hardcode a
    damage formula for this - it LEARNS the frontier from whether a trip
    actually cut anything, which is the ladder algorithm from CLAUDE.md.

  * **GRASS IS CUT ONCE AND STAYS CUT, and the StartLine does NOT undo that.**
    This one was read wrong first and the mistake is worth keeping written down.
    `Worlds.World_<n>.Safe_Zone_0.StartLine` is a 1x1x400 plane at x = -840.1 in
    world 1, and stepping back across it really does run
    `RestoreAllLocalGrass()` - measured, 646 blades in zone 1 with 112 cut went
    to 0 cut the moment the body crossed at x = -845.3. But that function only
    clears the CLIENT attribute. The server keeps its own copy, so what actually
    happens is that the client redraws a full field the server still has as
    mown: nothing blocks the body any more and every swing comes back
    `AttackPerformed(true, 0)`. Measured both ways - zone 1 after a local
    restore, 24 accepted attacks, **0** blades; zone 2, never touched, 16
    accepted attacks, **31** blades and two grass lines opened.

    So cutting is PERMANENT PROGRESS, not a lap. There is no going back and
    nothing here waits at the start line; the frontier only ever moves forward.

  * **The income is the LOOT, and that is what respawns.** Once a zone's grass is
    open the farm is a patrol of its SpawnZone, not another walk through the
    field. That is why the cutting pass fires only while the frontier is behind
    the target and the loot patrol gets the body the rest of the time.

  * Loot carries its whole record as attributes on the world model:
    `LootId`, `LootRarity`, `LootSellPrice`, `LootZoneIndex` and
    **`LootExpiresAt`** - it despawns, so the picker skips anything about to go.
    Pickup is a plain `PickupPrompt` with `MaxActivationDistance` 5; walk inside
    3.5 studs and fire it once. Confirmed by `LootService.LootPickedUp`, never
    by the prompt returning.

  * **`DataService:SellAllBackpackLoot()` is NOT position gated.** Three items
    sold from 133 studs away from the market for $405, `MoneyRaw` 105 -> 510. So
    there are no return trips in this script at all; the only walk back is the
    one that restores the grass.

  * The backpack starts at 3 slots (`GetBackpackSlotsState().Capacity`) and the
    Carry upgrade raises it. That cap is the reason loot is ranked on
    `LootSellPrice` rather than on distance.

  Never spends Robux: every honeypot remote above, the five gamepass training
  pads, `BuyCutterRobux`, `RobuxCarryButtonClicked` /
  `WalkSpeedRobuxButtonClicked` / `AttackSpeedRobuxButtonClicked` /
  `AttackRangeRobuxButtonClicked`, `RebirthRobuxButtonClicked`, the auras' and
  cutters' `RobuxPrice` (that field is only the OTHER way to pay for the same
  money-priced item - same trap as speedmonkey's trails), `QuestRewardsService
  .Purchase`, every Relics skip/guarantee product and the Lucky Wheel's paid
  spins.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local plr = Players.LocalPlayer

local GEN = (_G.__CUTGRASS or 0) + 1
_G.__CUTGRASS = GEN

--------------------------------------------------------------------------------
-- config
--------------------------------------------------------------------------------

local CONFIG = {
	auto = false,

	click = true,           -- the click engine, 12.5/s is the whole server budget
	train = true,           -- stand on the best FREE pad; it stacks with clicking
	trainSecs = 20,         -- seconds on the pad between cutting trips
	trainMinMult = 2,       -- do not walk off the lane for a pad weaker than this;
	                        -- x1.5 is +3/s against the click loop's 11.7/s anywhere
	trainMinShare = 0.25,   -- ...and it must also be worth at least this share of
	                        -- what clicking already pays, or the walk is a loss

	cut = true,             -- open the next zone; grass is cut once and stays cut
	loot = true,            -- pick up loot while out there - this is the only income
	tripSecs = 45,          -- how long the loot patrol gets before the lap restarts
	cutSecs = 25,           -- and how long the frontier push gets. Separate budgets
	                        -- on purpose: a deep zone can absorb a whole lap, and a
	                        -- lap that only cuts earns exactly nothing
	zoneMode = "Auto",      -- Auto (learned frontier) | Manual
	zoneTarget = 1,
	probeHoldSecs = 120,    -- after a zone walls the body, leave it alone this long
	                        -- and let the click loop grow the strength instead

	sell = true,            -- SellAllBackpackLoot, works from anywhere
	cutters = true,         -- DamageMult is the damage engine - first call on money
	auras = true,           -- StrengthMultiplier, money priced
	upgrades = true,        -- attack speed / range / carry / walk speed
	rebirth = true,         -- gated on the LEVEL, not on money
	worlds = true,          -- level gated: 185 / 380 / 570 / 750
	freebies = true,        -- offline, like reward, quests, free wheel spin

	reserveWindow = 90,     -- a cutter is fenced off once income can reach it in
	                        -- this many seconds - never as a share of the balance
}

local STATE = {
	phase = "idle",
	note = "ready",
	strength = 0, money = 0, level = 0, rebirths = 0,
	world = 1, zone = 1, zoneBest = 1, zoneProbe = 0,
	cutter = "-", cutterMult = 0, aura = "-", auraMult = 1,
	pad = "-", padMult = 0, clickAmount = 1,
	bag = 0, bagCap = 0, bagValue = 0,
	strRate = 0, moneyRate = 0,
	cutTotal = 0, lootTotal = 0, sold = 0, earned = 0, spent = 0,
	trips = 0, blocked = 0, homeTrips = 0, probeHold = 0,
	busy = false, halted = false,
}

--------------------------------------------------------------------------------
-- helpers (above their first caller - a Lua local is invisible above its own
-- definition and inside a pcall that surfaces as a quiet footer note)
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

local function note(text) STATE.note = tostring(text) end

local function char()
	local model = plr.Character
	if not model then return nil, nil, nil end
	return model, model:FindFirstChild("HumanoidRootPart"), model:FindFirstChildOfClass("Humanoid")
end

local function attr(name, default)
	local v = plr:GetAttribute(name)
	if v == nil then return default end
	return v
end

-- Every WaitForChild in games/ carries a timeout: in the right game it resolves
-- in milliseconds, in the wrong one an endless wait becomes a catchable error
-- instead of a parked bridge poll.
local function waitFor(parent, name, secs)
	if not parent then return nil end
	return parent:WaitForChild(name, secs or 10)
end

--------------------------------------------------------------------------------
-- knit, and the honeypot blacklist
--------------------------------------------------------------------------------

-- Resolved from the folder rather than from a pinned version string, so a Knit
-- bump does not silently take the whole script out.
local SERVICES
do
	local index = waitFor(waitFor(ReplicatedStorage, "Packages"), "_Index")
	if index then
		for _, pkg in ipairs(index:GetChildren()) do
			local knit = pkg:FindFirstChild("knit")
			local svc = knit and knit:FindFirstChild("Services")
			if svc then SERVICES = svc break end
		end
	end
end

-- Twenty decoy remotes, read straight out of `Configs.AntiCheat.IncidentReasons`.
-- One call is an immediate detect at risk 100 and they grant nothing whatsoever.
-- Nothing in this file targets any of them; this set is the belt on top of the
-- braces, because the cost of one slip here is the account.
local HONEYPOT = {
	AddCoins = true, AddCash = true, AddMoney = true, GiveCash = true,
	GiveCoins = true, GiveCurrency = true, GiveMoney = true,
	SetCash = true, SetCoins = true, SetCurrency = true, SetMoney = true,
	UpdateMoney = true, UpdateTokens = true, ClaimMoney = true,
	CollectMoney = true, ClaimAllRewards = true, SellAll = true,
	CollectAllLoot = true, RebirthAll = true, UpgradeAll = true, TrainAll = true,
}

local function remote(service, kind, name)
	if not SERVICES then return nil end
	local s = SERVICES:FindFirstChild(service)
	local folder = s and s:FindFirstChild(kind)
	return folder and folder:FindFirstChild(name) or nil
end

local function fire(service, event, ...)
	if HONEYPOT[event] then
		note("REFUSED honeypot remote " .. event)
		return false
	end
	local re = remote(service, "RE", event)
	if not re then return false end
	-- the varargs have to be captured here: `...` is not visible inside the
	-- anonymous function pcall wants, and that is a compile error, not a runtime one
	local args = table.pack(...)
	local ok = pcall(function() re:FireServer(table.unpack(args, 1, args.n)) end)
	return ok
end

-- Spin a Gun cost a whole session to `RequestClaimForeverGift`, a RemoteFunction
-- with no OnServerInvoke that parks its caller forever - and in the bridge that
-- caller is the poll loop. Every InvokeServer in this file goes through a spawned
-- thread behind a wall clock cap, so the worst case is one leaked parked thread.
local function call(service, fn, ...)
	local rf = remote(service, "RF", fn)
	if not rf then return nil, "no remote" end
	local args = table.pack(...)
	local done, ok, res = false, false, nil
	task.spawn(function()
		ok, res = pcall(function() return rf:InvokeServer(table.unpack(args, 1, args.n)) end)
		done = true
	end)
	local waited = 0
	while not done and waited < 8 do
		task.wait(0.1)
		waited = waited + 0.1
	end
	if not done then return nil, "timeout" end
	if not ok then return nil, tostring(res) end
	return res
end

--------------------------------------------------------------------------------
-- movement: MoveTo only, never a CFrame write and never WalkSpeed
--------------------------------------------------------------------------------

-- The Movement check samples every 0.2s and treats anything from 120 studs as an
-- unexcusable teleport; sustained speed above ~1.15x walkspeed over 2s is caught
-- too, and so is writing WalkSpeed (its own reason, `walkspeed_property`). So the
-- only mover in this file is the humanoid itself. It is slower than the warp every
-- other script in games/ uses, and it is the entire reason this one stays quiet.
local function walkTo(pos, timeout, tol)
	tol = tol or 4
	timeout = timeout or 20
	local started = os.clock()
	local stuckSince, lastD = os.clock(), nil
	while os.clock() - started < timeout do
		local _, hrp, hum = char()
		if not hrp or not hum then return false, "no body" end
		local d = (hrp.Position - pos).Magnitude
		if d <= tol then return true end
		if lastD and lastD - d < 0.5 then
			if os.clock() - stuckSince > 3.5 then return false, "stuck" end
		else
			stuckSince, lastD = os.clock(), d
		end
		hum:MoveTo(pos)
		task.wait(0.2)
	end
	return false, "timeout"
end

local function stopWalking()
	local _, hrp, hum = char()
	if hrp and hum then hum:MoveTo(hrp.Position) end
end

--------------------------------------------------------------------------------
-- world geography
--------------------------------------------------------------------------------

local function worldId() return math.floor(tonumber(attr("CurrentWorld", 1)) or 1) end

local function worldFolder()
	local worlds = workspace:FindFirstChild("Worlds")
	return worlds and worlds:FindFirstChild("World_" .. worldId()) or nil
end

local function zonesFolder()
	local zones = workspace:FindFirstChild("Zones")
	return zones and zones:FindFirstChild("W" .. worldId()) or nil
end

-- The safe zone's StartLine is both the grass restore trigger and the anchor the
-- whole trip is measured from. It is one part per world and it never streams out.
local function startLine()
	local w = worldFolder()
	local safe = w and w:FindFirstChild("Safe_Zone_0")
	local part = safe and safe:FindFirstChild("StartLine", true)
	if part and part:IsA("BasePart") then return part end
	return nil
end

-- The world's spawn point, which is both where the backpack load is cleared and
-- the anchor every long walk routes through. Defined up here with the rest of the
-- geography because trainPass needs it and a Lua local is invisible above its own
-- definition - the second time that caught this file.
local function basePos()
	local w = worldFolder()
	if not w then return nil end
	for _, c in ipairs(w:GetChildren()) do
		if c:IsA("BasePart") and c.Name:match("^Spawn_Point") then return c.Position end
	end
	local safe = w:FindFirstChild("Safe_Zone_0")
	local ok, p = pcall(function() return safe and safe:GetPivot().Position end)
	if ok and p then return p end
	return nil
end

-- Zones stream, so a position read from the base comes back nil and a picker built
-- on that farms zone 1 forever (the wingsbrainrots trap). Every position ever seen
-- is cached in _G, which also survives a re-execute, and an unseen zone is
-- extrapolated from the last measured gap rather than guessed at zero.
--
-- The cache is keyed under its own NAME rather than reusing an older one: a table
-- in _G outlives the code that wrote it and so does its SHAPE, and this one grew a
-- Z when the first version stored a bare X. A stale entry of the old shape would
-- have indexed a number with 'z' in a game that had been running fine.
_G.__CUTGRASS_ZPOS = _G.__CUTGRASS_ZPOS or {}

local function zoneModel(i)
	local zf = zonesFolder()
	return zf and zf:FindFirstChild("Zone_" .. i) or nil
end

-- Returns the X of the zone and the Z of the CORRIDOR it sits on. The Z matters as
-- much as the X: the grass lines and the loot both live in a ~88 stud band around
-- the corridor centre, so a trip that keeps whatever Z it happened to start on
-- walks past the entire zone without touching it. That is exactly what the first
-- build did - it left the training pad at z = -78 and mowed thin air.
local function zonePos(i)
	local key = worldId() .. ":" .. i
	local m = zoneModel(i)
	if m then
		local spawn = m:FindFirstChild("SpawnZone")
		local ok, p = pcall(function()
			return (spawn and spawn.Position) or m:GetPivot().Position
		end)
		if ok and p then
			_G.__CUTGRASS_ZPOS[key] = { x = p.X, z = p.Z }
			return p.X, p.Z
		end
	end
	local hit = _G.__CUTGRASS_ZPOS[key]
	if type(hit) == "table" then return hit.x, hit.z end
	-- extrapolate from the two deepest known zones of this world
	local known = {}
	for k, v in pairs(_G.__CUTGRASS_ZPOS) do
		local w, idx = k:match("^(%d+):(%d+)$")
		if tonumber(w) == worldId() and type(v) == "table" then
			known[#known + 1] = { tonumber(idx), v.x, v.z }
		end
	end
	table.sort(known, function(a, b) return a[1] < b[1] end)
	if #known == 0 then return nil, nil end
	local last = known[#known]
	local gap = 100
	if #known >= 2 then
		local prev = known[#known - 1]
		gap = (last[2] - prev[2]) / math.max(1, last[1] - prev[1])
	end
	return last[2] + gap * (i - last[1]), last[3]
end

local function zoneCount()
	local zf = zonesFolder()
	if not zf then return 9 end
	local n = 0
	for _, c in ipairs(zf:GetChildren()) do
		if c.Name:match("^Zone_%d+$") then n = n + 1 end
	end
	return math.max(n, 1)
end

-- Total grass models in a zone and how many the CLIENT currently draws as cut.
--
-- DIAGNOSTIC ONLY - do not drive anything off this. `GD_LocalGrassHidden` is the
-- client's own mark, and `RestoreAllLocalGrass` clears every one of them the
-- moment the body steps back across the StartLine while the server keeps its own
-- copy. A pass built on this counter reported a full field and cut nothing for a
-- whole trip. The server's `AttackPerformed(accepted, count)` receipt is the real
-- signal; this is kept for looking at a zone by hand through the debug table.
local function grassCounts(i)
	local z = zoneModel(i)
	if not z then return 0, 0 end
	local total, hidden = 0, 0
	for _, line in ipairs(z:GetChildren()) do
		if line.Name == "GrassLine" then
			for _, chunk in ipairs(line:GetChildren()) do
				for _, blade in ipairs(chunk:GetChildren()) do
					total = total + 1
					if blade:GetAttribute("GD_LocalGrassHidden") then hidden = hidden + 1 end
				end
			end
		end
	end
	return total, hidden
end

--------------------------------------------------------------------------------
-- the click engine
--------------------------------------------------------------------------------

local function clickOnce() return fire("StrengthService", "ClickRequested") end

--------------------------------------------------------------------------------
-- training pads
--------------------------------------------------------------------------------

local PadConfig
do
	local ok, cfg = pcall(function()
		pcall(function() setthreadidentity(2) end)
		return require(waitFor(waitFor(waitFor(ReplicatedStorage, "Shared"), "Configs"), "TrainingPads"))
	end)
	if ok then PadConfig = cfg end
end

-- The gamepass pads (x10, x25, x100, x300, x1000) are filtered on the FIELD
-- `GamepassId`, never on the name - the same rule that stopped strengthclick
-- walking onto a `Rebirth = 99999999999999` zone and powerclick reading
-- `TrainingPad_x100` as a x100 when the attribute said 75.
local function bestPad()
	if not PadConfig or not PadConfig.Pads then return nil end
	local w = worldFolder()
	local folder = w and w:FindFirstChild("TrainZones")
	if not folder then return nil end
	local reb = tonumber(attr("RebirthLevel", 0)) or 0
	local best, bestMult = nil, -1
	for _, model in ipairs(folder:GetChildren()) do
		local cfg
		for id, entry in pairs(PadConfig.Pads) do
			if model.Name == id or model.Name == tostring(entry.Id) then cfg = entry break end
		end
		-- the world models are TrainZone_<n> while the config keys are Training_<n>
		if not cfg then
			local n = model.Name:match("TrainZone_(%d+)$")
			if n then cfg = PadConfig.Pads["Training_" .. n] end
		end
		if cfg and not cfg.GamepassId and not cfg.ShowRobux then
			local mult = tonumber(cfg.Multiplier) or 0
			local req = tonumber(cfg.RequiredRebirths) or 0
			if reb >= req and mult > bestMult then
				local part = model:FindFirstChild("Grass_Zone") or model:FindFirstChild("Hitbox")
					or model:FindFirstChild("Pad") or model:FindFirstChild("Area")
				local ok, pos = pcall(function()
					return (part and part.Position) or model:GetPivot().Position
				end)
				if ok and pos then
					best, bestMult = { model = model, cfg = cfg, pos = pos, mult = mult }, mult
				end
			end
		end
	end
	return best
end

local function trainPass(secs)
	if secs <= 0 then return end
	local pad = bestPad()
	if not pad then
		note("no free training pad in reach")
		return
	end
	STATE.pad, STATE.padMult = tostring(pad.cfg.DisplayName or pad.cfg.Id), pad.mult

	-- Whether a pad is worth walking to is a RATIO, not a fixed multiplier, and
	-- getting that wrong sent the body 900 studs across the map for nothing.
	-- Measured at ClickAmount 1: the free x1.5 pad pays 2.75 strength/s (a pulse of
	-- `Multiplier` every 0.5s) and the click loop pays 11.66/s, so a pad is worth
	-- about 1.83 x its multiplier while a click is worth 11.66 x ClickAmount. The
	-- cutter multiplies ClickAmount and nothing else, so by the time a x750 cutter
	-- is equipped the click loop makes ~140/s and the x2 pad adds under 3% - for a
	-- round trip that also abandons the loot patrol. `trainMinMult` stays as a
	-- floor for the early game; this is the test that keeps being right later.
	local padWorth = 1.83 * pad.mult
	local clickWorth = 11.66 * math.max(1, STATE.clickAmount or 1)
	if pad.mult < CONFIG.trainMinMult
		or (CONFIG.click and padWorth < clickWorth * CONFIG.trainMinShare) then
		STATE.phase = "clicking, pad not worth the walk"
		return
	end
	STATE.phase = "training"
	-- The pads sit beside the base and the farm is out in the zones, so a direct
	-- walk is 800+ studs across the whole map and dies on the first grass blocker
	-- it meets sideways - "pad walk: stuck" was that, every lap. Go home first;
	-- the base is a straight run down the lane and the pads are a few steps off it.
	local _, hrp = char()
	local base = basePos()
	if hrp and base and (hrp.Position - pad.pos).Magnitude > 150 then
		walkTo(base, 90, 10)
	end
	local ok, why = walkTo(pad.pos, 40, 5)
	if not ok then
		note("pad walk: " .. tostring(why))
		return
	end
	stopWalking()
	local until_ = os.clock() + secs
	while os.clock() < until_ and CONFIG.auto and CONFIG.train and GEN == _G.__CUTGRASS and not STATE.halted do
		task.wait(0.25)
	end
end

--------------------------------------------------------------------------------
-- loot
--------------------------------------------------------------------------------

-- Forward declared on purpose. A Lua local is invisible above its own definition,
-- and because every pass here runs inside a pcall that resolves to a quiet footer
-- note rather than a crash - which is how a shared helper went missing for 300
-- lines in lootevo. The body is assigned further down, next to the other spenders.
local sellPass

-- `Count` is the BACKPACK LOAD, not a number of items, and that distinction is the
-- whole shape of the trip. Selling empties `Items` and pays out - from anywhere -
-- but the load does NOT move: measured, three items sold for $450 and `Count`
-- stayed 3 with `Items` empty and `TotalSellPrice` 0, and every later pickup was
-- refused because the bag reads full. `ResetBackpackLoadAtBase` is what clears it
-- and it is position gated: `false` from 220 studs out in the field, `true`
-- standing on the world's spawn point, load 3 -> 0. So a trip really does have to
-- come home, and selling early only means the money is already in hand when it
-- does.
local function bagState()
	local st = call("DataService", "GetBackpackSlotsState")
	if type(st) ~= "table" then return nil end
	STATE.bag = tonumber(st.BackpackLoad) or tonumber(st.Count) or 0
	STATE.bagCap = tonumber(st.Capacity) or 0
	return st
end

-- Walk home and empty the bag. Everything else in the trip is optional; this is
-- the step without which the second lap collects nothing at all.
local function homePass()
	if STATE.bagCap > 0 and STATE.bag <= 0 then return true end
	local base = basePos()
	if not base then
		note("no spawn point found for world " .. worldId())
		return false
	end
	STATE.phase = "going home"
	local ok = walkTo(base, 90, 8)
	if not ok then
		note("could not reach base to empty the bag")
		return false
	end
	stopWalking()
	task.wait(0.4)
	local res = call("LootInventoryService", "ResetBackpackLoadAtBase")
	task.wait(0.4)
	bagState()
	if res == true or STATE.bag <= 0 then
		STATE.homeTrips = (STATE.homeTrips or 0) + 1
		return true
	end
	note("base refused the backpack reset")
	return false
end

-- A target that could not be reached must be STRUCK OFF, or the ranking hands the
-- same one straight back on the next pass and the patrol earns nothing at all -
-- three measurement windows in Roll A Gnome went by at exactly zero that way.
-- Weak keys, so a despawned loot model does not keep its entry alive.
local lootStrikes = setmetatable({}, { __mode = "k" })

-- Loot despawns: `LootExpiresAt` is a wall clock stamp on the model. A target that
-- expires before the walk finishes is a slot's worth of nothing, so it is skipped
-- rather than chased - the same reason drainwater ranks fish before claiming them.
local function lootCandidates()
	local out = {}
	local _, hrp = char()
	if not hrp then return out end
	local zf = zonesFolder()
	if not zf then return out end
	local now = os.time()
	for _, zone in ipairs(zf:GetChildren()) do
		local spawn = zone:FindFirstChild("SpawnZone")
		if spawn then
			for _, model in ipairs(spawn:GetChildren()) do
				local price = tonumber(model:GetAttribute("LootSellPrice"))
				local struck = lootStrikes[model]
				if struck and struck > os.clock() then price = nil end
				if price then
					local expires = tonumber(model:GetAttribute("LootExpiresAt")) or (now + 60)
					local ok, pos = pcall(function() return model:GetPivot().Position end)
					if ok and pos then
						local dist = (pos - hrp.Position).Magnitude
						-- walking is ~22 studs/s; anything that dies before we arrive
						-- plus a second of settle is not a candidate at all
						if expires - now > dist / 20 + 1.5 then
							out[#out + 1] = {
								model = model, pos = pos, price = price, dist = dist,
								rarity = tostring(model:GetAttribute("LootRarity") or "?"),
							}
						end
					end
				end
			end
		end
	end
	table.sort(out, function(a, b)
		if a.price ~= b.price then return a.price > b.price end
		return a.dist < b.dist
	end)
	return out
end

local function grabLoot(entry)
	-- The walk budget has to come from the DISTANCE. A flat 10s looks generous
	-- standing in the zone and is nowhere near enough from the base: the best loot
	-- was 310 studs away, the character walks 22 studs/s, so every attempt timed
	-- out halfway and the patrol re-picked the same item forever.
	local budget = math.clamp(entry.dist / 10 + 5, 8, 75)
	local ok = walkTo(entry.pos, budget, 3.2)
	if not ok then
		lootStrikes[entry.model] = os.clock() + 25
		return false
	end
	stopWalking()
	task.wait(0.25)
	local prompt
	for _, d in ipairs(entry.model:GetDescendants()) do
		if d:IsA("ProximityPrompt") then prompt = d break end
	end
	if not prompt then return false end
	local before = STATE.bag
	pcall(function() fireproximityprompt(prompt) end)
	task.wait(0.55)
	-- confirm on the server's own count, never on the prompt returning
	bagState()
	if STATE.bag > before then
		STATE.lootTotal = STATE.lootTotal + 1
		return true
	end
	-- arrived and the prompt still did not hand it over: strike it too rather than
	-- standing on it for the rest of the trip
	lootStrikes[entry.model] = os.clock() + 15
	return false
end

--------------------------------------------------------------------------------
-- the cutting trip
--------------------------------------------------------------------------------

local attackRemote

local function attackOnce()
	if not attackRemote then attackRemote = remote("AttackService", "RE", "AttackRequested") end
	if not attackRemote then return false end
	local ok = pcall(function() attackRemote:FireServer() end)
	return ok
end

-- THE ONLY HONEST "did that cut anything" SIGNAL.
--
-- `AttackPerformed(accepted, count)` is a server -> client receipt and `count` is
-- the number of blades the server actually took. Everything else lies:
-- `GD_LocalGrassHidden` is the CLIENT's copy, and `RestoreAllLocalGrass` - which
-- runs whenever you step back across the StartLine - clears it wholesale. That
-- redraws grass the server still has as cut, so a counter built on the attribute
-- reports a full field, no blocker stops the body, and every attack comes back
-- `count = 0` with nothing to cut. Measured both ways: zone 1 after a local
-- restore, 24 accepted attacks, count 0, not one blade; zone 2, never touched,
-- 16 accepted attacks, count 31. Grass is cut ONCE per player and stays cut.
local cutSinceMark = 0
do
	local re = remote("AttackService", "RE", "AttackPerformed")
	if re then
		re.OnClientEvent:Connect(function(accepted, count)
			if accepted then
				local n = tonumber(count) or 0
				cutSinceMark = cutSinceMark + n
				STATE.cutTotal = STATE.cutTotal + n
			end
		end)
	end
end

-- Target zone. In Auto this is the LEARNED frontier, not a computed one: a damage
-- formula would have to guess how Strength, the cutter's DamageMult and the aura
-- combine, and a wrong guess sends the body to a wall it can never cut. Instead a
-- trip that cut nothing demotes the cursor and a run of good trips probes one
-- deeper - the ladder from CLAUDE.md, with an empty result counted as a failure.
local function targetZone()
	if CONFIG.zoneMode == "Manual" then
		return math.clamp(math.floor(CONFIG.zoneTarget), 1, zoneCount())
	end
	local z = math.clamp(STATE.zoneBest, 1, zoneCount())
	-- Cutting is permanent, so the target is always the NEXT zone unless the last
	-- attempt at it was walled - then it is left alone for a while and the strength
	-- is allowed to grow instead of the body standing at grass it cannot cut. The
	-- first version re-walked the already-open zone instead, which cost a whole
	-- 45 second pass per lap for nothing.
	if os.clock() < (STATE.probeHold or 0) then return z end
	return math.min(z + 1, zoneCount())
end

-- PUSH THE FRONTIER.
--
-- Grass is cut once and stays cut, so this is not a lap - it is permanent
-- progress, and the body simply walks +X along the lane swinging until either the
-- target zone is reached or the wall stops paying. Being stopped is the honest
-- signal that the grass ahead outranks the current damage; the ladder below reads
-- it off `cutSinceMark`, the server's own count, rather than off anything local.
--
-- The blocker welded to the character is what holds the body at standing grass,
-- and it is left strictly alone: it is the reason the GrassNoclip check never has
-- anything to look at.
local function cutPass()
	local zone = targetZone()
	STATE.zone = zone
	local goal, lane = zonePos(zone)
	if not goal then
		note("zone " .. zone .. " position unknown yet")
		return
	end
	local line = startLine()
	lane = lane or (line and line.Position.Z) or 1

	STATE.phase = "cutting"
	STATE.trips = STATE.trips + 1
	local probing = (CONFIG.zoneMode == "Auto") and zone > STATE.zoneBest

	local _, hrp = char()
	if not hrp then return end

	-- get onto the lane first; the grass and the loot both live in a band around
	-- it, and a trip that keeps whatever Z it started on mows thin air
	if math.abs(hrp.Position.Z - lane) > 12 then
		STATE.phase = "to lane"
		walkTo(Vector3.new(hrp.Position.X, hrp.Position.Y, lane), 25, 6)
		STATE.phase = "cutting"
	end

	cutSinceMark = 0
	local lastX = select(2, char()) and select(2, char()).Position.X or 0
	local noProgress = 0

	local deadline = os.clock() + CONFIG.cutSecs
	local nextAttack = 0
	while os.clock() < deadline and CONFIG.auto and CONFIG.cut and GEN == _G.__CUTGRASS and not STATE.halted do
		local _, root, hum = char()
		if not root or not hum then break end

		if os.clock() >= nextAttack then
			attackOnce()
			nextAttack = os.clock() + 0.52   -- Attack.Cooldown is a hard 0.5s
		end

		hum:MoveTo(Vector3.new(goal, root.Position.Y, lane))

		if root.Position.X >= goal - 6 then
			-- arrived: this zone is open, nothing left to cut here
			break
		end

		if root.Position.X - lastX < 0.4 then
			noProgress = noProgress + 1
		else
			noProgress = 0
			lastX = root.Position.X
		end

		-- Standing at a wall is only a failure if the server is also taking
		-- nothing. Deep grass takes many swings per blade, so a body that is not
		-- advancing but IS still cutting is working exactly as intended.
		if noProgress > 20 then
			if cutSinceMark > 0 then
				noProgress = 0
				cutSinceMark = 0
			else
				STATE.blocked = STATE.blocked + 1
				break
			end
		end
		task.wait(0.5)
	end

	stopWalking()
	local _, endPos = char()
	local reached = endPos and endPos.Position.X >= goal - 10

	-- the ladder: reaching the zone opens it, being walled without cutting a
	-- single blade demotes the cursor. An empty result is a failure, never a pass.
	if CONFIG.zoneMode == "Auto" then
		if reached then
			if zone > STATE.zoneBest then
				STATE.zoneBest = zone
				note("zone " .. zone .. " opened - frontier moved")
			end
			STATE.probeHold = 0
		elseif probing then
			-- walled. Sitting there swinging is what a damage formula would have
			-- made this script do forever; instead the zone is parked and the
			-- click loop is left to grow the strength that opens it.
			STATE.probeHold = os.clock() + CONFIG.probeHoldSecs
			note("zone " .. zone .. " is beyond this cutter - farming " .. STATE.zoneBest)
		end
	end
end

-- THE INCOME. Loot respawns in the SpawnZones on its own timer, so once a zone is
-- open the farm is a patrol rather than another walk through the grass. Only zones
-- at or below the frontier are considered: loot lying behind standing grass is
-- unreachable and chasing it parks the body at a wall for the whole trip.
local function lootPass()
	-- full means the LOAD is full, and only the base clears that, so there is
	-- nothing useful to do out here - the cycle takes it home
	if STATE.bagCap > 0 and STATE.bag >= STATE.bagCap then
		STATE.phase = "bag full"
		return
	end
	local cands = lootCandidates()
	local best
	for _, c in ipairs(cands) do
		local zi = tonumber(c.model:GetAttribute("LootZoneIndex")) or 1
		if zi <= STATE.zoneBest then
			-- walking is the real cost here, so the ranking is value per trip, not
			-- raw price: the deepest open zone wins on price by orders of magnitude
			-- anyway and this only stops a marginal item pulling the body backwards
			local score = c.price / (1 + c.dist / 40)
			if not best or score > best.score then
				best = { entry = c, score = score }
			end
		end
	end
	if not best then
		STATE.phase = "no loot in reach"
		return
	end
	STATE.phase = "looting"
	grabLoot(best.entry)
end

--------------------------------------------------------------------------------
-- selling
--------------------------------------------------------------------------------

function sellPass()
	local st = call("DataService", "GetBackpackLootSellState")
	if type(st) ~= "table" then return end
	STATE.bagValue = tonumber(st.TotalSellPrice) or 0
	local count = tonumber(st.Count) or 0
	if count <= 0 then return end
	local res = call("DataService", "SellAllBackpackLoot")
	if type(res) == "table" and res.Success then
		STATE.sold = STATE.sold + (tonumber(res.SoldCount) or 0)
		STATE.earned = STATE.earned + (tonumber(res.Earned) or 0)
		note("sold " .. tostring(res.SoldCount) .. " for $" .. short(res.Earned))
	end
	bagState()
end

--------------------------------------------------------------------------------
-- spending
--------------------------------------------------------------------------------

-- ONE shared guard, asked by every spender. Reserving for the cheapest item is
-- what abandoned the 5,000,000 Drill Speed in Sell Ores; the reserve here is for
-- the next CUTTER, which is the damage engine, and it only engages once the
-- balance can actually reach it from income inside a window. A step that repays in
-- seconds bypasses it, or the guard becomes the starvation pattern itself.
local reserveTarget = 0

local function spendable(cost)
	local money = tonumber(attr("MoneyRaw", 0)) or 0
	if cost > money then return false end
	if reserveTarget <= 0 then return true end
	if cost <= money * 0.02 then return true end      -- trivially cheap, let it through
	local rate = math.max(0, STATE.moneyRate)
	local reachable = reserveTarget <= money + rate * CONFIG.reserveWindow
	if not reachable then return true end             -- not reachable: do not hoard
	return money - cost >= reserveTarget
end

local function cutterPass()
	local st = call("CuttersShopService", "GetShopState")
	if type(st) ~= "table" then return end
	local cat = st.CuttersData or call("CuttersShopService", "GetCatalog")
	if type(cat) ~= "table" then return end
	local owned = st.OwnedCutters or {}
	local current = tostring(st.CurrentCutter or "")
	local curMult = 0
	for name, c in pairs(cat) do
		if name == current then curMult = tonumber(c.DamageMult) or 0 end
	end
	STATE.cutter, STATE.cutterMult = current, curMult

	local world = worldId()
	local money = tonumber(attr("MoneyRaw", 0)) or 0

	-- Two separate questions, and the first build ran them together and bought
	-- nothing for it: "what is the strongest cutter I could hold" is NOT "what
	-- should I buy". Ranking every entry above the worn one by DamageMult picks
	-- the 2.5e29 Aether Saw every pass, so the balance is never enough, nothing is
	-- ever bought - and because that price also became the reserve, it froze the
	-- auras and the upgrades along with it. Best AFFORDABLE, always, and the
	-- reserve is only ever the NEXT rung.
	local bestOwned, bestOwnedMult = nil, curMult
	local buy, buyCost, buyMult = nil, 0, curMult
	local saveFor, saveCost = nil, math.huge

	for name, c in pairs(cat) do
		if type(c) == "table" then
			local mult = tonumber(c.DamageMult) or 0
			local price = tonumber(c.Price) or 0
			local reqWorld = tonumber(c.RequiredWorld) or 1
			if owned[name] and mult > bestOwnedMult then
				bestOwned, bestOwnedMult = name, mult
			end
			-- Price 0 next to a RobuxPrice is a gamepass cutter, never a free one -
			-- a cheapest-first sort would otherwise put all three of them at the top
			if not owned[name] and mult > curMult and price > 0 and world >= reqWorld then
				if price <= money then
					if mult > buyMult then buy, buyCost, buyMult = name, price, mult end
				elseif price < saveCost then
					saveFor, saveCost = name, price
				end
			end
		end
	end

	-- owning and holding are different things: a rejoin, or a purchase made while
	-- the panel was off, can leave a weaker cutter in hand and it costs nothing to
	-- put the right one back on
	if bestOwned then
		call("CuttersShopService", "EquipCutter", bestOwned)
		note("equipped owned " .. bestOwned)
		return
	end

	if buy then
		local res = call("CuttersShopService", "BuyCutter", buy)
		if res then
			STATE.spent = STATE.spent + buyCost
			note("bought cutter " .. buy .. " x" .. short(buyMult))
			call("CuttersShopService", "EquipCutter", buy)
		end
		reserveTarget = 0
		return
	end

	reserveTarget = saveFor and saveCost or 0
end

local function auraPass()
	local st = call("AuraService", "GetState")
	if type(st) ~= "table" or type(st.Items) ~= "table" then return end
	local world = worldId()
	local curMult = 1
	local equipped = tostring(st.EquippedAura or "")
	for _, item in pairs(st.Items) do
		if item.Equipped then curMult = tonumber(item.StrengthMultiplier) or 1 end
	end
	STATE.aura, STATE.auraMult = (equipped ~= "" and equipped or "-"), curMult

	-- an owned aura is free to put back on
	for id, item in pairs(st.Items) do
		if item.Owned and not item.Equipped and (tonumber(item.StrengthMultiplier) or 0) > curMult then
			call("AuraService", "BuyOrToggleAura", id)
			note("equipped owned aura " .. tostring(item.DisplayName or id))
			return
		end
	end

	local buy, cost, mult = nil, math.huge, curMult
	for id, item in pairs(st.Items) do
		local price = tonumber(item.Price) or 0
		local m = tonumber(item.StrengthMultiplier) or 0
		local reqWorld = tonumber(item.RequiredWorld) or 1
		-- RobuxPrice is only the other way to pay for the same money-priced aura
		if not item.Owned and price > 0 and m > curMult and world >= reqWorld then
			if m > mult or (m == mult and price < cost) then buy, cost, mult = id, price, m end
		end
	end
	if not buy then return end
	if not spendable(cost) then return end
	local res = call("AuraService", "BuyOrToggleAura", buy)
	if res then
		STATE.spent = STATE.spent + cost
		note("bought aura " .. buy .. " x" .. tostring(mult))
	end
end

-- The four money upgrades are plain button events with no reply, so the only
-- confirmation is the balance moving. A refused one prints a red "not enough
-- money" across the player's screen (the Spin a Gun lesson), so a failure parks
-- that entry until the balance has grown by half again, and the cursor
-- round-robins instead of restarting at the top - a fixed order buys the first
-- affordable entry forever and starves the rest.
local UPGRADES = { "AttackSpeedButtonClicked", "AttackRangeButtonClicked", "CarryButtonClicked", "SpeedButtonClicked" }
local upgradeCursor = 1
local upgradeBlocked = {}

local function upgradePass()
	local money = tonumber(attr("MoneyRaw", 0)) or 0
	for i = 1, #UPGRADES do
		local idx = ((upgradeCursor + i - 2) % #UPGRADES) + 1
		local name = UPGRADES[idx]
		local blockedUntil = upgradeBlocked[name]
		if not blockedUntil or money >= blockedUntil then
			if spendable(money * 0.05) then
				local before = money
				fire("UpgradesService", name)
				task.wait(0.6)
				local after = tonumber(attr("MoneyRaw", 0)) or 0
				if after < before then
					upgradeBlocked[name] = nil
					STATE.spent = STATE.spent + (before - after)
					upgradeCursor = idx + 1
					return
				end
				upgradeBlocked[name] = before * 1.5
			end
		end
	end
	upgradeCursor = upgradeCursor + 1
end

--------------------------------------------------------------------------------
-- rebirth, worlds, free rewards
--------------------------------------------------------------------------------

local function rebirthPass()
	local st = call("RebirtService", "GetState")
	if type(st) ~= "table" then return end
	STATE.rebirths = tonumber(st.RebirthLevel) or STATE.rebirths
	STATE.level = tonumber(st.PlayerLevel) or STATE.level
	if not st.CanRebirth then return end
	-- the Robux twin sits right next to this one; only the plain button is fired
	fire("RebirtService", "RebirthButtonClicked")
	note("rebirth -> level " .. tostring(st.NextRebirthLevel))
	task.wait(1.5)
end

local function worldPass()
	local st = call("WorldService", "GetState")
	if type(st) ~= "table" then return end
	local cur = tonumber(st.CurrentWorld) or 1
	local unlocked = tonumber(st.HighestUnlockedWorld) or cur
	STATE.world = cur
	if unlocked > cur then
		call("WorldService", "TeleportToWorld", unlocked)
		note("travelling to world " .. unlocked)
		task.wait(3)
	end
end

local function freePass()
	local off = call("DataService", "GetOfflineRewardState")
	if type(off) == "table" and (off.CanClaim or off.Available or off.Pending) then
		call("DataService", "ClaimOfflineReward")
	end
	local like = call("DataService", "GetLikeRewardState")
	if type(like) == "table" and (like.CanClaim or like.Available) then
		call("DataService", "ClaimLikeReward")
	end
	local quests = call("QuestProgressService", "GetState")
	if type(quests) == "table" then
		local list = quests.Quests or quests.Items or quests
		if type(list) == "table" then
			for key, q in pairs(list) do
				if type(q) == "table" and q.Completed and not q.Claimed then
					call("QuestProgressService", "ClaimQuest", q.Id or key)
					task.wait(0.3)
				end
			end
		end
	end
	-- the wheel is only touched when the server says a FREE spin is banked;
	-- RequestSpin with none left is how a game opens a Robux window
	local wheel = call("LuckyWheelService", "GetState")
	if type(wheel) == "table" then
		local free = tonumber(wheel.FreeSpins or wheel.Spins or 0) or 0
		if wheel.CanClaimFreeSpin or wheel.CanClaim then call("LuckyWheelService", "ClaimSpin") end
		if free > 0 then call("LuckyWheelService", "RequestSpin") end
	end
end

--------------------------------------------------------------------------------
-- refresh
--------------------------------------------------------------------------------

-- The frontier is a MONOTONIC FACT about the account, not a guess: grass is cut
-- once and stays cut, so a zone that has been opened is open forever. Re-executing
-- the script does not restart the Lua VM but it does rebuild STATE, and the first
-- build lost the frontier every reload and walked back out from zone 1. Same rule
-- as the sticky rebirth count in spingun - a monotonic fact must survive a bad
-- read, and here it must survive a reload too. Keyed under its own name so an old
-- table of a different shape can never be read back.
_G.__CUTGRASS_FRONTIER = _G.__CUTGRASS_FRONTIER or {}

local function rememberFrontier()
	local key = "w" .. worldId()
	local best = tonumber(_G.__CUTGRASS_FRONTIER[key]) or 1
	if STATE.zoneBest > best then
		_G.__CUTGRASS_FRONTIER[key] = STATE.zoneBest
	elseif best > STATE.zoneBest then
		STATE.zoneBest = best
	end
end

local function refresh()
	rememberFrontier()
	STATE.strength = tonumber(attr("StrengthRaw", 0)) or 0
	STATE.money = tonumber(attr("MoneyRaw", 0)) or 0
	STATE.level = tonumber(attr("StrengthLevel", 0)) or 0
	STATE.rebirths = tonumber(attr("RebirthLevel", 0)) or 0
	STATE.world = worldId()
	if STATE.zoneBest < 1 then STATE.zoneBest = 1 end
end

-- `ClickAmount` is what a single click is worth after the cutter, the aura, the
-- rebirth multiplier and the potions, and it is the number the training-pad
-- decision is measured against. Read on a slow timer rather than in refresh():
-- it is a round trip to the server and it moves only when something is bought.
local function statePass()
	local s = call("StrengthService", "GetState")
	if type(s) ~= "table" then return end
	STATE.clickAmount = tonumber(s.ClickAmount) or STATE.clickAmount
	STATE.level = tonumber(s.Level) or STATE.level
end

local function unstuck()
	CONFIG.auto = false
	STATE.busy = false
	STATE.halted = false
	local _, hrp, hum = char()
	if hum then
		hum.PlatformStand = false
		pcall(function() hum:ChangeState(Enum.HumanoidStateType.GettingUp) end)
	end
	if hrp then hrp.Anchored = false end
	local scripts = plr:FindFirstChild("PlayerScripts")
	local pm = scripts and scripts:FindFirstChild("PlayerModule")
	if pm then pcall(function() require(pm):GetControls():Enable() end) end
	stopWalking()
	STATE.phase = "idle"
	note("unstuck, auto off")
end

--------------------------------------------------------------------------------
-- the anti-cheat listener - the one thing in here that is not optional
--------------------------------------------------------------------------------

-- The server pushes IncidentWarning at the client it just recorded, and the game's
-- own AntiCheatController does nothing with it except draw a box. If it ever
-- arrives here, something in this file is wrong: everything stops, and it stays
-- stopped until a human reads the reason.
do
	local re = remote("AntiCheatService", "RE", "IncidentWarning")
	if re then
		re.OnClientEvent:Connect(function(payload)
			STATE.halted = true
			CONFIG.auto = false
			local reason = "unknown"
			if type(payload) == "table" then
				reason = tostring(payload.Reason or payload.reason or payload.Check or payload.Title or reason)
			elseif payload ~= nil then
				reason = tostring(payload)
			end
			note("ANTI-CHEAT WARNING: " .. reason .. " - everything stopped")
			warn("[cutgrass] anti-cheat incident: " .. reason)
		end)
	end
end

--------------------------------------------------------------------------------
-- loops
--------------------------------------------------------------------------------

local function loop(sec, key, fn, needsBody)
	task.spawn(function()
		while GEN == _G.__CUTGRASS do
			if CONFIG.auto and not STATE.halted and (key == nil or CONFIG[key])
				and not (needsBody and STATE.busy) then
				local ok, err = pcall(fn)
				if not ok then note(tostring(key) .. " failed: " .. tostring(err)) end
			end
			task.wait(sec)
		end
	end)
end

-- The click is position free and costs nothing to run beside everything else, so
-- it is its own thread rather than a step in the cycle. 0.075s, not per frame:
-- the server credits one call per 0.08s and a Heartbeat loop throws 93% of them
-- away while queueing the rest behind itself.
task.spawn(function()
	while GEN == _G.__CUTGRASS do
		if CONFIG.auto and CONFIG.click and not STATE.halted then
			clickOnce()
			task.wait(0.075)
		else
			task.wait(0.3)
		end
	end
end)

-- live read-out, running whether the farm does or not
task.spawn(function()
	local lastS, lastM, lastT = nil, nil, os.clock()
	while GEN == _G.__CUTGRASS do
		pcall(refresh)
		local now = os.clock()
		local dt = now - lastT
		if dt >= 4 then
			if lastS then STATE.strRate = math.max(0, (STATE.strength - lastS) / dt) end
			if lastM then STATE.moneyRate = math.max(0, (STATE.money - lastM) / dt) end
			lastS, lastM, lastT = STATE.strength, STATE.money, now
		end
		task.wait(1)
	end
end)

-- One body, one owner: the trip and the training run back to back in one thread
-- instead of three loops pulling the character in different directions.
task.spawn(function()
	while GEN == _G.__CUTGRASS do
		if CONFIG.auto and not STATE.halted and (CONFIG.cut or CONFIG.train or CONFIG.loot) then
			STATE.busy = true

			-- 1. SELL first, then go home and empty the load. Selling is free from
			--    anywhere, so the money is already in hand for the shop pass; the
			--    load is what has to come back, and until it is cleared every
			--    pickup out in the field is silently refused.
			if CONFIG.sell then pcall(sellPass) end
			pcall(bagState)
			if STATE.bagCap > 0 and STATE.bag > 0 then
				local ok, err = pcall(homePass)
				if not ok then note("home failed: " .. tostring(err)) end
			end

			-- 2. The pads sit beside the base, so training is nearly free right
			--    here and costs a long detour anywhere else in the lap.
			if CONFIG.train and CONFIG.trainSecs > 0 then
				local ok, err = pcall(trainPass, CONFIG.trainSecs)
				if not ok then note("train failed: " .. tostring(err)) end
			end

			-- 3. Push the frontier, but only when there is something to open.
			--    Cutting is permanent progress, not a lap.
			if CONFIG.cut and targetZone() > STATE.zoneBest then
				local ok, err = pcall(cutPass)
				if not ok then note("cut failed: " .. tostring(err)) end
			end

			-- 4. Fill the bag. This is the only income in the game.
			if CONFIG.loot then
				local until_ = os.clock() + CONFIG.tripSecs
				while os.clock() < until_ and CONFIG.auto and CONFIG.loot
					and GEN == _G.__CUTGRASS and not STATE.halted do
					if STATE.bagCap > 0 and STATE.bag >= STATE.bagCap then break end
					local ok, err = pcall(lootPass)
					if not ok then note("loot failed: " .. tostring(err)) break end
					if STATE.phase == "no loot in reach" then break end
					task.wait(0.2)
				end
			end
			STATE.busy = false
		else
			STATE.phase = "idle"
		end
		task.wait(0.4)
	end
end)

loop(6, "sell", sellPass)
loop(12, "cutters", cutterPass)
loop(18, "auras", auraPass)
loop(9, "upgrades", upgradePass)
loop(15, "rebirth", rebirthPass)
loop(30, "worlds", worldPass)
loop(150, "freebies", freePass)
loop(5, nil, bagState)
loop(20, nil, statePass)
task.spawn(function() task.wait(2) pcall(statePass) end)

--------------------------------------------------------------------------------
-- panel
--------------------------------------------------------------------------------

local UI = (_G.__SEL and _G.__SEL.ui) or loadstring(readfile("ui-template.lua"))()

if _G.__CUTGRASS_WIN then pcall(function() _G.__CUTGRASS_WIN:Destroy() end) end

-- gethui() can THROW rather than return nil (heroevo), and the usual
-- `(gethui and gethui()) or CoreGui` guard only checks that the function exists.
local hiddenRoot
pcall(function() hiddenRoot = gethui and gethui() end)

-- The list is built by APPENDING, never as a literal: `{ gethui() or nil, CoreGui }`
-- leaves a hole and ipairs stops at it, so on an executor without gethui the
-- fallback would never be tried. And PlayerGui is in here because that is where the
-- template actually landed in this game - a sweep of CoreGui alone reported "no
-- panel" while the window was on screen, and a re-execute would have stacked a
-- second one on top of it.
local roots = {}
if hiddenRoot then roots[#roots + 1] = hiddenRoot end
roots[#roots + 1] = game:GetService("CoreGui")
roots[#roots + 1] = plr:FindFirstChildOfClass("PlayerGui")
for _, root in ipairs(roots) do
	for _, g in ipairs(root:GetChildren()) do
		if g.Name == "CutGrassPanel" then pcall(function() g:Destroy() end) end
	end
end

UI.config("cutgrass", CONFIG)

local win = UI.Window({
	name = "CutGrassPanel",
	title = "CUT", accentTitle = "GRASS", subtitle = "seltonmt",
	badge = "🌿", width = 820, height = 582,
})
_G.__CUTGRASS_WIN = win

local page = win:Page("FARM", UI.icon.bolt)

local main = page:Card("LOOP", 1):Accent()
main:Toggle("AUTO", CONFIG.auto, function(v)
	CONFIG.auto = v
	STATE.phase = v and "farming" or "idle"
	if not v then stopWalking() end
	note(v and "running" or "stopped")
end, "click, train, cut, collect, sell, repeat", UI.theme.good)
main:Toggle("Click", CONFIG.click, function(v) CONFIG.click = v end,
	"12.5 strength/s is the whole server budget - it is paced, not spammed", UI.theme.good)
main:Toggle("Training pad", CONFIG.train, function(v) CONFIG.train = v end,
	"stacks with clicking: 2.75/s alone, 13.37/s together", UI.theme.good)
main:Slider("Train secs/trip", 0, 90, CONFIG.trainSecs, function(v) CONFIG.trainSecs = v end)
main:Slider("Min pad multiplier", 1, 15, CONFIG.trainMinMult, function(v) CONFIG.trainMinMult = v end)
main:Toggle("Cut grass", CONFIG.cut, function(v) CONFIG.cut = v end,
	"opens the next zone - grass is cut once and stays cut, so this is progress")
main:Toggle("Pick up loot", CONFIG.loot, function(v) CONFIG.loot = v end,
	"the only income - ranked on sell price, skips loot about to despawn", UI.theme.good)
main:Slider("Loot secs/lap", 15, 120, CONFIG.tripSecs, function(v) CONFIG.tripSecs = v end)
main:Slider("Cut secs/lap", 10, 90, CONFIG.cutSecs, function(v) CONFIG.cutSecs = v end)

local zonecard = page:Card("ZONE", 2)
zonecard:Dropdown("Zone pick", { "Auto", "Manual" }, CONFIG.zoneMode, function(v) CONFIG.zoneMode = v end)
zonecard:Stepper("Manual zone", function() return tostring(CONFIG.zoneTarget) end, function(dir)
	CONFIG.zoneTarget = math.clamp(CONFIG.zoneTarget + dir, 1, 13)
end, "only used while Zone pick is Manual")
zonecard:Slider("Hold a walled zone (s)", 30, 300, CONFIG.probeHoldSecs, function(v) CONFIG.probeHoldSecs = v end)
zonecard:Label("Auto always pushes for the next zone. One that walls the body is left alone for a while so the click loop can grow the strength that opens it. Grass health runs 50 in zone 1 to 700B in zone 15.")

local spend = page:Card("SPENDING", 1)
spend:Toggle("Cutters", CONFIG.cutters, function(v) CONFIG.cutters = v end,
	"DamageMult is the damage engine, so it gets the money first", UI.theme.good)
spend:Toggle("Auras", CONFIG.auras, function(v) CONFIG.auras = v end,
	"money priced, x1.2 up to x300 strength - RobuxPrice is only the other way to pay")
spend:Toggle("Upgrades", CONFIG.upgrades, function(v) CONFIG.upgrades = v end,
	"attack speed, range, carry and walk speed, round-robin so none starves")
spend:Toggle("Auto rebirth", CONFIG.rebirth, function(v) CONFIG.rebirth = v end,
	"gated on your LEVEL, and it unlocks the next free training pads", UI.theme.good)
spend:Toggle("Travel worlds", CONFIG.worlds, function(v) CONFIG.worlds = v end,
	"level gated: 185 / 380 / 570 / 750")
spend:Toggle("Free rewards", CONFIG.freebies, function(v) CONFIG.freebies = v end,
	"offline, like reward, finished quests, and a wheel spin only when one is banked")
spend:Slider("Reserve window (s)", 15, 300, CONFIG.reserveWindow, function(v) CONFIG.reserveWindow = v end)

local manual = page:Card("MANUAL", 2)
manual:Button("Trip now", function() task.spawn(cutPass) end)
manual:Button("Sell all", function() task.spawn(sellPass) end)
manual:Button("Shop now", function() task.spawn(function() cutterPass() auraPass() end) end)
manual:Button("Claim free", function() task.spawn(freePass) end)
manual:Button("Unstuck", unstuck, UI.theme.bad)

local safety = page:Card("ANTI-CHEAT", 0):Accent()
safety:Label("This game detects speed, teleports and walking through uncut grass, and it has twenty honeypot remotes where one call is an instant record. This script never warps, never writes WalkSpeed and never touches those remotes - it walks. If the server ever sends a warning, everything here stops by itself.")

local out = page:Card("STATUS", 0):Readout(14, function(text)
	if text:find("^AUTO") then return UI.theme.good end
	if text:find("ANTI%-CHEAT") or text:find("^HALTED") then return UI.theme.bad end
	return nil
end)

task.spawn(function()
	while GEN == _G.__CUTGRASS do
		local lines = {
			STATE.halted and "HALTED BY ANTI-CHEAT WARNING" or (CONFIG.auto and "AUTO RUNNING" or "STOPPED"),
			"  phase     " .. tostring(STATE.phase),
			"  strength  " .. short(STATE.strength) .. "   " .. short(STATE.strRate) .. "/s",
			"  money     $" .. short(STATE.money) .. "   $" .. short(STATE.moneyRate) .. "/s",
			"  level     " .. tostring(STATE.level) .. "   rebirths " .. tostring(STATE.rebirths)
				.. "   world " .. tostring(STATE.world),
			"  zone      " .. tostring(STATE.zone) .. "   open to " .. tostring(STATE.zoneBest)
				.. ((os.clock() < (STATE.probeHold or 0))
					and string.format("   next held %.0fs", (STATE.probeHold - os.clock())) or "   probing next"),
			"  cutter    " .. tostring(STATE.cutter) .. "   x" .. short(STATE.cutterMult),
			"  aura      " .. tostring(STATE.aura) .. "   x" .. tostring(STATE.auraMult),
			"  pad       " .. tostring(STATE.pad) .. "   x" .. tostring(STATE.padMult)
				.. "   click x" .. short(STATE.clickAmount),
			"  backpack  " .. tostring(STATE.bag) .. "/" .. tostring(STATE.bagCap)
				.. "   worth $" .. short(STATE.bagValue),
			"  trips     " .. tostring(STATE.trips) .. "   walled " .. tostring(STATE.blocked)
				.. "   home " .. tostring(STATE.homeTrips) .. "   grass cut " .. short(STATE.cutTotal),
			"  loot      " .. tostring(STATE.lootTotal) .. " taken   " .. tostring(STATE.sold) .. " sold",
			"  earned    $" .. short(STATE.earned) .. "   spent $" .. short(STATE.spent),
			"  " .. tostring(STATE.note),
		}
		pcall(function() out:set(lines) end)
		pcall(function()
			win:SetStatus(string.format("$%s   str %s   lv%s   zone %s   %s",
				short(STATE.money), short(STATE.strength), tostring(STATE.level),
				tostring(STATE.zone), tostring(STATE.phase)))
		end)
		pcall(function()
			win:SetStat(1, "$" .. short(STATE.money), "money")
			win:SetStat(2, short(STATE.strength), "strength")
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
		if not on then stopWalking() end
	end)
end)

pcall(function() win:Home() end)

win:Refresh()

--------------------------------------------------------------------------------

_G.__CUTGRASS_DBG = {
	CONFIG = CONFIG, STATE = STATE, GEN = GEN,
	short = short, note = note, attr = attr,
	fire = fire, call = call, remote = remote, HONEYPOT = HONEYPOT,
	walkTo = walkTo, stopWalking = stopWalking,
	worldId = worldId, worldFolder = worldFolder, zonesFolder = zonesFolder,
	startLine = startLine, zoneModel = zoneModel, zonePos = zonePos, zoneCount = zoneCount,
	grassCounts = grassCounts,
	clickOnce = clickOnce, attackOnce = attackOnce,
	bestPad = bestPad, trainPass = trainPass,
	bagState = bagState, lootCandidates = lootCandidates, grabLoot = grabLoot,
	basePos = basePos, homePass = homePass,
	targetZone = targetZone, cutPass = cutPass, lootPass = lootPass, sellPass = sellPass,
	cutSince = function() return cutSinceMark end,
	spendable = spendable, cutterPass = cutterPass, auraPass = auraPass,
	upgradePass = upgradePass, rebirthPass = rebirthPass, worldPass = worldPass,
	freePass = freePass, refresh = refresh, unstuck = unstuck, statePass = statePass,
	rememberFrontier = rememberFrontier,
}

print("[cutgrass] gen " .. GEN .. " ready - RightShift for the panel")
