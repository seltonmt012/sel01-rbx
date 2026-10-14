--[[ ballvsball.lua - Ball VS Ball (ATYS 3), place 96510596525082

  Auto-battle PvP. Sit at a duel table, pick one of three balls, aim the
  launch arrow, and the server simulates the fight and streams the replay.
  3 HP Mode: a lost round costs a heart, three hearts and the match is over.
  Measured 2026-10-14 - see games-autobattler.md "ballvsball" for the numbers.

  THE FIGHT IS A DETERMINISTIC SIMULATION, AND IT SHIPS TO THE CLIENT.
  ReplicatedStorage.BattleDemo.BattleSimulation, fed the round's seed, both
  balls, their upgrades and both launch directions, gives the server's result
  exactly: 12 of 12 foreign replays re-simulated to the same winner. The seed
  of round r is round 1's seed + (r-1) * 1009, so from round 2 on the only
  unknown left is the opponent's arrow - and a player who does not touch it
  keeps last round's direction, because the game's aim client remembers it
  per table.

  So the arrow is chosen by playing the round out before it happens: every
  candidate direction against the likely opponent arrows, on the known seed
  (a handful of sampled seeds in round 1), and the best expected result is
  locked through the game's own aim session.
]]

local Players    = game:GetService("Players")
local RS         = game:GetService("ReplicatedStorage")

if not game:IsLoaded() then game.Loaded:Wait() end
local plr = Players.LocalPlayer
while not plr do
	task.wait(0.1)
	plr = Players.LocalPlayer
end
local UID = plr.UserId
local PLACE = 96510596525082

local ENV
do
	local ok, g = pcall(function() return getgenv() end)
	ENV = (ok and type(g) == "table") and g or _G
end
ENV.__BVB = (ENV.__BVB or 0) + 1
local GEN = ENV.__BVB
local function alive() return ENV.__BVB == GEN end

if ENV.__BVB_CONN then
	for _, c in ipairs(ENV.__BVB_CONN) do pcall(function() c:Disconnect() end) end
end
ENV.__BVB_CONN = {}

--------------------------------------------------------------------------------
-- remotes and modules
--------------------------------------------------------------------------------

-- Every remote is a sleitnick Net remote under Packages._Index; the version is
-- in the folder name, so it is looked up rather than spelled out.
local NET
do
	local pk = RS:WaitForChild("Packages", 30)
	local idx = pk and pk:WaitForChild("_Index", 30)
	local t0 = os.clock()
	while not NET and idx and os.clock() - t0 < 30 do
		for _, c in ipairs(idx:GetChildren()) do
			if c.Name:find("sleitnick_net", 1, true) and c:FindFirstChild("net") then
				NET = c.net
				break
			end
		end
		if not NET then task.wait(0.5) end
	end
end

local function ev(name) return NET and NET:FindFirstChild("RE/" .. name) end
local function rf(name) return NET and NET:FindFirstChild("RF/" .. name) end

local function fire(name, ...)
	local r = ev(name)
	if not r then return false end
	return (pcall(r.FireServer, r, ...))
end

-- A RemoteFunction the server never answers parks the caller for good, so
-- every call runs in its own thread behind a wall-clock cap.
local function invoke(name, ...)
	local r = rf(name)
	if not r then return nil, "missing" end
	local args = table.pack(...)
	local box = { done = false }
	task.spawn(function()
		local ok, v = pcall(function() return r:InvokeServer(table.unpack(args, 1, args.n)) end)
		box.res = ok and v or { ok = false, reason = tostring(v) }
		box.done = true
	end)
	local t0 = os.clock()
	while not box.done and os.clock() - t0 < 12 do task.wait(0.1) end
	if not box.done then return nil, "timeout" end
	return box.res
end

local function req(inst)
	if not inst then return nil end
	local ok, m = pcall(require, inst)
	return ok and m or nil
end

local Engine = RS:WaitForChild("Engine", 30)
local Demo = RS:WaitForChild("BattleDemo", 30)
local Service = Engine and Engine:FindFirstChild("Service")
local Config = req(Service and Service:FindFirstChild("Config")) or {}
local PD = req(Service and Service:FindFirstChild("PlayerData"))
local BC = req(Demo and Demo:FindFirstChild("BattleConfig"))
local BS = req(Demo and Demo:FindFirstChild("BattleSimulation"))
local ORC = req(Service and Service:FindFirstChild("OnlineRewardConfig"))

-- PlayerData.client.___X is the live replicated save: coins, diamonds,
-- items, quests, online seconds - exactly what the server holds.
local function D()
	local c = PD and PD.client
	return (c and type(c.___X) == "table") and c.___X or {}
end
local function serverNow() return workspace:GetServerTimeNow() end
local function coins() return tonumber(D().coins) or 0 end
local function diamonds() return tonumber(D().diamonds) or 0 end

local function ballName(role)
	local b = Config.ball and Config.ball.byCnId and Config.ball.byCnId[role]
	return (b and b.displayName) or tostring(role or "?")
end

local function ownedBalls()
	local seen, n = {}, 0
	for _, it in pairs(D().items or {}) do
		if type(it) == "table" and it.itemType == "Ball" and it.itemId and not seen[it.itemId] then
			seen[it.itemId] = true
			n = n + 1
		end
	end
	return n, seen
end

--------------------------------------------------------------------------------
-- config and state
--------------------------------------------------------------------------------

local CONFIG = {
	auto        = false,     -- the master switch: nothing below acts while it is off
	autoQueue   = true,      -- quick play into a free seat whenever not seated
	leaveEmpty  = 45,        -- seconds alone at a table before trying another (0 = stay)
	smartPick   = true,      -- best ball by the server's own win-rate table
	freePick    = true,      -- spend the free once-per-match pick from the collection
	smartAim    = true,      -- simulate the round and lock the best arrow
	aimQuality  = "Normal",  -- Fast | Normal | Best
	smartUpgrade = true,     -- simulate each upgrade card and take the best
	rewards     = true,      -- online rewards, daily quests, mail, check-in
	codes       = true,
	buyBalls    = true,      -- Coins Ball Gacha, 600 coins a ball
	coinReserve = 0,
	antiAfk     = true,
}

local STATE = {
	phase = "starting", note = "",
	matchWins = 0, matchLosses = 0, roundWins = 0, roundLosses = 0, roundDraws = 0,
	seedHits = 0, seedMiss = 0, parityHits = 0, parityMiss = 0,
	queues = 0, rolls = 0, rewards = 0, codes = 0, coinsEarned = 0,
	lastAim = nil, lastPick = nil, lastUpgrade = nil, predSum = 0, predN = 0,
}

local function note(s) STATE.note = tostring(s) end

--------------------------------------------------------------------------------
-- event plumbing
--------------------------------------------------------------------------------

-- Small waiters so a solver can fire a request and wait for its answer
-- without a second connection per call.
local waiters = {}
local function dispatch(name, args)
	for i = #waiters, 1, -1 do
		local w = waiters[i]
		if w.name == name and (not w.pred or w.pred(table.unpack(args, 1, args.n))) then
			w.box.done, w.box.args = true, args
			table.remove(waiters, i)
		end
	end
end
local function waitFor(name, pred, timeout)
	local box = { done = false }
	local w = { name = name, pred = pred, box = box }
	table.insert(waiters, w)
	local t0 = os.clock()
	while not box.done and alive() and os.clock() - t0 < (timeout or 4) do task.wait(0.05) end
	local i = table.find(waiters, w)
	if i then table.remove(waiters, i) end
	return box.done and box.args or nil
end

local function on(name, fn)
	local r = ev(name)
	if not r then return end
	table.insert(ENV.__BVB_CONN, r.OnClientEvent:Connect(function(...)
		if not alive() then return end
		local args = table.pack(...)
		if fn then
			local ok, err = pcall(fn, ...)
			if not ok then note(name .. ": " .. tostring(err)) end
		end
		dispatch(name, args)
	end))
end

--------------------------------------------------------------------------------
-- the server's win-rate table
--------------------------------------------------------------------------------

-- RF BallBattleStats/GetAll: per ball, wins/losses/draws against every other
-- ball, tens of millions of fights for the common ones. Rate limited, so it is
-- refreshed every ten minutes at most.
local WR = { data = nil, glob = {}, at = -1e9 }
local function refreshStats(force)
	if not force and os.clock() - WR.at < 600 then return end
	WR.at = os.clock()
	local r = invoke("BallBattleStats/GetAll")
	local data = type(r) == "table" and (type(r.data) == "table" and r.data or r) or nil
	if type(data) ~= "table" or next(data) == nil then return end
	local glob = {}
	for role, v in pairs(data) do
		local w, l, d = 0, 0, 0
		for _, s in pairs(type(v) == "table" and type(v.opponents) == "table" and v.opponents or {}) do
			w = w + (tonumber(s.wins) or 0)
			l = l + (tonumber(s.losses) or 0)
			d = d + (tonumber(s.draws) or 0)
		end
		local n = w + l + d
		if n > 0 then glob[role] = (w + d * 0.5) / n end
	end
	WR.data, WR.glob = data, glob
end

local function winRate(role)
	return WR.glob[role] or 0.5
end

-- head to head: this ball against that one, from the same table
local function h2h(role, opp)
	local d = WR.data and WR.data[role]
	local s = opp and d and type(d.opponents) == "table" and d.opponents[opp]
	if type(s) == "table" then
		local w, l, dr = tonumber(s.wins) or 0, tonumber(s.losses) or 0, tonumber(s.draws) or 0
		local n = w + l + dr
		if n >= 200 then return (w + dr * 0.5) / n, n end
	end
	return winRate(role), 0
end

--------------------------------------------------------------------------------
-- the simulation
--------------------------------------------------------------------------------

local SIM_DT = (BC and BC.replay and tonumber(BC.replay.fixedDt)) or (1 / 60)
local SIM_MAX = math.ceil(((BC and BC.replay and tonumber(BC.replay.maxDuration)) or 90) / SIM_DT)
local SEED_STEP = 1009
local RNG = Random.new()

-- the same sum BattleReplayBuilder uses for the HP bars
local function sumTeam(st, team, field)
	local list = st.teams and st.teams[team]
	if not list then
		local b = st.balls and st.balls[team]
		return b and (b[field] or 0) or 0
	end
	local s = 0
	for _, k in pairs(list) do
		local b = st.balls[k]
		s = s + (b and (b[field] or 0) or 0)
	end
	return s
end

local function simulate(seed, roles, traits, stats, dirs)
	local sim = BS.new(BC, seed, roles, traits, stats, dirs)
	for _ = 1, SIM_MAX do
		local st = sim:step(SIM_DT)
		if st.finished then break end
	end
	return sim:getState()
end

-- 1 win, 0.5 draw, 0 loss, plus the HP lead as a tie-breaker
local function outcome(st, me, opp)
	local w = st.finished and st.winner or "Draw"
	local s = (w == me) and 1 or ((w == opp) and 0 or 0.5)
	local mh, mm = sumTeam(st, me, "hp"), sumTeam(st, me, "maxHp")
	local oh, om = sumTeam(st, opp, "hp"), sumTeam(st, opp, "maxHp")
	return s, (mm > 0 and mh / mm or 0) - (om > 0 and oh / om or 0)
end

-- One sim is ~30 ms, so a frame is let through after every one of them and
-- the client keeps drawing at a usable rate while the solver runs.
local frameStart = os.clock()
local function breathe()
	if os.clock() - frameStart > 0.025 then
		task.wait()
		frameStart = os.clock()
	end
end

local function dirOf(a) return Vector2.new(math.cos(a), math.sin(a)) end
local function angleOf(v) return math.atan2(v.Y, v.X) end
local function spawnOf(team)
	local s = BC and BC.slots and BC.slots[team]
	return (s and typeof(s.spawnPosition) == "Vector2") and s.spawnPosition or Vector2.zero
end
local function towardEnemy(me, opp)
	local d = spawnOf(opp) - spawnOf(me)
	if d.Magnitude < 1e-6 then return Vector2.new(1, 0) end
	return d.Unit
end
local function angDiff(a, b)
	local d = (a - b) % (2 * math.pi)
	if d > math.pi then d = d - 2 * math.pi end
	return d
end

--------------------------------------------------------------------------------
-- the match
--------------------------------------------------------------------------------

-- The table we sit at and everything known about the match on it. Kept in
-- getgenv so a re-execute mid-match keeps the seed base and the opponent's
-- arrows instead of starting the next round blind.
local M = ENV.__BVB_MATCH

local function freshMatch(m)
	m.round, m.seedBase, m.seedOk = 0, nil, true
	m.lastOpts, m.oppDirs, m.oppRoles = nil, {}, {}
	m.myDir, m.pendingCard, m.freeUsed = nil, nil, false
	m.predSeed, m.predRound, m.lastPred = nil, nil, nil
end

local function sides(t)
	local myTeam, myRole
	for k, p in pairs(t.players or {}) do
		if type(p) == "table" and p.userId == UID then
			myTeam = type(p.team) == "string" and p.team or tostring(k)
			myRole = p.roleId
		end
	end
	if not myTeam then return nil end
	for k, p in pairs(t.players or {}) do
		if type(p) == "table" and p.userId ~= UID then
			local team = type(p.team) == "string" and p.team or tostring(k)
			if team ~= myTeam then return myTeam, myRole, team, p.userId, p.roleId end
		end
	end
	return myTeam, myRole, nil, nil, nil
end

local function currentStatsTraits(m)
	local stats, traits = {}, {}
	for _, team in ipairs({ m.team, m.opp }) do
		stats[team] = { allIn = 0, speed = 0, hp = 0, attack = 0 }
		traits[team] = {}
	end
	local o = m.lastOpts
	if o then
		for team, v in pairs(type(o.statLevels) == "table" and o.statLevels or {}) do
			if type(v) == "table" then stats[team] = table.clone(v) end
		end
		for team, v in pairs(type(o.selectedSecondaryTraits) == "table" and o.selectedSecondaryTraits or {}) do
			if type(v) == "table" then traits[team] = table.clone(v) end
		end
	end
	return stats, traits
end

-- a basic stat card raises its level by one, an effect card joins the traits:
-- that is how the server records them in the next replay's options
local function applyCard(card, stats, traits, team)
	if card.kind == "basicStat" then
		local s = stats[team]
		if type(s) == "table" then s[card.id] = (tonumber(s[card.id]) or 0) + 1 end
	elseif card.kind == "effect" then
		local t = traits[team]
		if type(t) == "table" and not table.find(t, card.id) then t[#t + 1] = card.id end
	end
end

local solveAim, solvePick, solveUpgrade

local function onTable(t)
	local myTeam, myRole, oppTeam, oppUid, oppRole = sides(t)
	if not myTeam then return false end
	if not M or M.tableId ~= t.tableId then
		M = { tableId = t.tableId }
		freshMatch(M)
		ENV.__BVB_MATCH = M
	end
	if typeof(t.table) == "Instance" then M.table = t.table end
	local prev = M.state
	M.team, M.state, M.hp, M.endsAt = myTeam, t.state, t.hp or {}, t.countdownEndsAt
	M.teamSize, M.mode = tonumber(t.teamSize) or 1, t.gameMode
	if oppUid and M.oppUid and oppUid ~= M.oppUid then freshMatch(M) end
	if oppUid then M.oppUid, M.opp = oppUid, oppTeam end
	M.myRole, M.oppRole = myRole, oppRole

	-- Did they pick by themselves? A ball that shows up in the state during
	-- Picking was chosen; one that first appears with Aiming was handed out by
	-- the server at the timeout - an AFK player, who will not aim either.
	if t.state == "Picking" then
		if prev ~= "Picking" then
			M.oppPickedSelf = false
			M.pickStart = serverNow()
		end
		if oppRole then M.oppPickedSelf = true end
	elseif t.state == "Aiming" and prev == "Picking" then
		M.oppAfk = not M.oppPickedSelf
	end

	if t.state == "Waiting" or t.state == "Countdown" then
		if prev and prev ~= "Waiting" and prev ~= "Countdown" then freshMatch(M) end
		if oppUid then M.aloneSince = nil else M.aloneSince = M.aloneSince or os.clock() end
	else
		M.aloneSince = nil
	end

	if t.state == "Aiming" and myRole and oppRole and M.opp and M.aimKey ~= t.countdownEndsAt then
		M.aimKey = t.countdownEndsAt
		task.spawn(function()
			local ok, err = pcall(solveAim, M, t)
			if not ok then note("aim: " .. tostring(err)) end
		end)
	end
	return true
end

local function onState(p)
	if type(p) ~= "table" then return end
	if type(p.tables) == "table" then
		local found = false
		for _, t in pairs(p.tables) do
			if type(t) == "table" and onTable(t) then found = true end
		end
		if not found then M = nil end
	elseif p.tableId then
		if not onTable(p) and M and M.tableId == p.tableId then M = nil end
	end
	ENV.__BVB_MATCH = M
end

local function onReplay(p)
	if type(p) ~= "table" or p.kind ~= "replay" or not M or p.tableId ~= M.tableId then return end
	local o = type(p.replayOptions) == "table" and p.replayOptions or {}
	local round = tonumber(p.round) or 0
	local seed = tonumber(p.seed)
	if M.predSeed and M.predRound == round then
		if seed == M.predSeed then
			STATE.seedHits = STATE.seedHits + 1
		else
			STATE.seedMiss = STATE.seedMiss + 1
			M.seedOk = false
		end
	end
	M.predSeed, M.predRound = nil, nil
	-- where round 1's seed comes from is still open; keep our own pick time
	-- next to it so the relation can be read off later
	if seed and round == 1 then
		STATE.seedDiag = STATE.seedDiag or {}
		table.insert(STATE.seedDiag, {
			seed = seed / 1000, pickedAt = M.pickedAt, pickStart = M.pickStart,
			oppAfk = M.oppAfk, oppPickedSelf = M.oppPickedSelf,
		})
		if #STATE.seedDiag > 20 then table.remove(STATE.seedDiag, 1) end
	end
	if seed and round >= 1 then M.seedBase = seed - (round - 1) * SEED_STEP end
	M.round, M.lastOpts, M.pendingCard = round, o, nil
	local dirs = type(o.initialDirections) == "table" and o.initialDirections or {}
	if M.opp and typeof(dirs[M.opp]) == "Vector2" then table.insert(M.oppDirs, dirs[M.opp]) end
	if typeof(dirs[M.team]) == "Vector2" then M.myDir = dirs[M.team] end
	local roles = type(o.selectedRoles) == "table" and o.selectedRoles or {}
	if M.opp and roles[M.opp] then table.insert(M.oppRoles, roles[M.opp]) end

	local won = p.winnerUserId == UID
		or (type(p.winnerUserIds) == "table" and table.find(p.winnerUserIds, UID) ~= nil)
	local actual = (p.isDraw == true) and 0.5 or (won and 1 or 0)
	if p.isDraw == true then
		STATE.roundDraws = STATE.roundDraws + 1
	elseif won then
		STATE.roundWins = STATE.roundWins + 1
	else
		STATE.roundLosses = STATE.roundLosses + 1
	end
	if M.lastPred then
		STATE.predSum = STATE.predSum + (actual - M.lastPred)
		STATE.predN = STATE.predN + 1
		M.lastPred = nil
	end
	if p.matchFinished == true then
		if won then
			STATE.matchWins = STATE.matchWins + 1
		elseif p.isDraw ~= true then
			STATE.matchLosses = STATE.matchLosses + 1
		end
	end

	-- the replay names every input, so our copy of the simulation can be
	-- checked against the server's every round, for free
	if BS and BC then
		task.spawn(function()
			local ok, st = pcall(simulate, seed, o.selectedRoles, o.selectedSecondaryTraits, o.statLevels, o.initialDirections)
			if not ok or not st then return end
			local w = st.finished and st.winner or "Draw"
			local serverW = p.isDraw == true and "Draw" or (won and M and M.team or (M and M.opp))
			if w == serverW then STATE.parityHits = STATE.parityHits + 1 else STATE.parityMiss = STATE.parityMiss + 1 end
		end)
	end
end

--------------------------------------------------------------------------------
-- aiming
--------------------------------------------------------------------------------

local QUALITY = {
	Fast   = { dirs = 16, seeds = 2, refine = 1 },
	Normal = { dirs = 24, seeds = 3, refine = 2 },
	Best   = { dirs = 36, seeds = 4, refine = 3 },
}
local LOCK_MARGIN = 2.5  -- seconds before the server's own timeout

-- The game's aim client (DuelLaunchAimClient): locking through its session
-- draws our arrow, marks it locked and cancels its own auto-lock, so the
-- client never sends a second direction behind ours.
local aimClientRef = setmetatable({}, { __mode = "v" })
local function aimClient()
	local a = aimClientRef[1]
	if a then return a end
	if not getgc then return nil end
	for _, t in ipairs(getgc(true)) do
		if type(t) == "table" and rawget(t, "launchDirectionRemote") and rawget(t, "lastDirectionByTable") then
			aimClientRef[1] = t
			return t
		end
	end
	return nil
end

local function lockDirection(m, dir)
	local a = aimClient()
	local s = a and a.session
	if s and s.tableModel == m.table and not s.locked then
		s.direction = dir
		pcall(function() a:_applyArrowDirection(s) end)
		local ok = pcall(function() a:_confirmLock() end)
		if ok and s.locked then return "game" end
	end
	if m.table and fire("DuelTableLaunchDirection", m.table, dir) then return "remote" end
	return nil
end

-- What the opponent's arrow probably is. The game's default is straight at us
-- +-5 degrees in round 1 and last round's arrow after that; a player who timed
-- out gets a random one from the server. The weights follow that.
local function oppModel(m)
	local toward = towardEnemy(m.opp, m.team)
	local base = angleOf(toward)
	local list = {}
	local function add(d, w) list[#list + 1] = { d = d, w = w } end
	local n = #m.oppDirs
	local last = m.oppDirs[n]
	if m.oppAfk then
		-- timed out on the pick, so the aim times out too and the server
		-- hands them a random direction: be good against any arrow
		add(toward, 0.16)
		for i = 0, 5 do add(dirOf(base + math.pi / 6 + i * math.pi / 3 + RNG:NextNumber(-0.3, 0.3)), 0.14) end
	elseif last then
		local steady = n >= 2 and math.abs(angDiff(angleOf(last), angleOf(m.oppDirs[n - 1]))) < math.rad(2)
		local wl = steady and 0.8 or 0.5
		add(last, wl)
		local rest = 1 - wl
		add(toward, rest * 0.4)
		add(dirOf(base + math.rad(5)), rest * 0.2)
		add(dirOf(base - math.rad(5)), rest * 0.2)
		add(dirOf(RNG:NextNumber(0, 2 * math.pi)), rest * 0.2)
	else
		add(toward, 0.5)
		add(dirOf(base + math.rad(4)), 0.15)
		add(dirOf(base - math.rad(4)), 0.15)
		add(dirOf(RNG:NextNumber(0, 2 * math.pi)), 0.2)
	end
	return list
end

solveAim = function(m, t)
	if not (alive() and CONFIG.auto and CONFIG.smartAim and BS and BC) then return end
	if (m.teamSize or 1) > 1 then return end  -- 2v2 arrows are per seat; the game's default stands
	local q = QUALITY[CONFIG.aimQuality] or QUALITY.Normal
	local lockAt = (tonumber(t.countdownEndsAt) or (serverNow() + 30)) - LOCK_MARGIN
	local roles = { [m.team] = m.myRole, [m.opp] = m.oppRole }
	local stats, traits = currentStatsTraits(m)
	if m.pendingCard then applyCard(m.pendingCard, stats, traits, m.team) end

	local seeds, exact = {}, false
	if m.seedBase and m.seedOk and m.round >= 1 then
		seeds[1] = m.seedBase + m.round * SEED_STEP
		exact = true
		m.predSeed, m.predRound = seeds[1], m.round + 1
	else
		for i = 1, q.seeds do
			seeds[i] = math.floor(serverNow() * 1000) - RNG:NextInteger(0, 90000)
		end
	end

	local opps = oppModel(m)
	local myBase = angleOf(towardEnemy(m.team, m.opp))
	local cands = {}
	for i = 0, q.dirs - 1 do
		cands[#cands + 1] = { a = myBase + 2 * math.pi * i / q.dirs, s = 0, mg = 0, w = 0 }
	end
	if m.myDir then cands[#cands + 1] = { a = angleOf(m.myDir), s = 0, mg = 0, w = 0 } end

	STATE.phase = "aiming"
	local t0, sims = os.clock(), 0
	frameStart = os.clock()
	local function stillMine() return alive() and M == m and m.state == "Aiming" end
	local function eval(c)
		for _, seed in ipairs(seeds) do
			for _, o in ipairs(opps) do
				if not stillMine() or serverNow() > lockAt then return false end
				local ok, st = pcall(simulate, seed, roles, traits, stats, { [m.team] = dirOf(c.a), [m.opp] = o.d })
				sims = sims + 1
				if ok and st then
					local s, mg = outcome(st, m.team, m.opp)
					c.s, c.mg, c.w = c.s + s * o.w, c.mg + mg * o.w, c.w + o.w
				end
				breathe()
			end
		end
		return true
	end
	local function score(c) return c.w > 0 and c.s / c.w or -1 end
	local function margin(c) return c.w > 0 and c.mg / c.w or -1 end
	local function rank()
		table.sort(cands, function(x, y)
			local sx, sy = score(x), score(y)
			if math.abs(sx - sy) > 1e-9 then return sx > sy end
			return margin(x) > margin(y)
		end)
	end

	-- seed-major order, so a partial pass still compares every direction on
	-- the same inputs if time runs out
	local complete = true
	for si, seed in ipairs(seeds) do
		for _, o in ipairs(opps) do
			for _, c in ipairs(cands) do
				if not stillMine() then return end
				if serverNow() > lockAt then complete = false break end
				local ok, st = pcall(simulate, seed, roles, traits, stats, { [m.team] = dirOf(c.a), [m.opp] = o.d })
				sims = sims + 1
				if ok and st then
					local s, mg = outcome(st, m.team, m.opp)
					c.s, c.mg, c.w = c.s + s * o.w, c.mg + mg * o.w, c.w + o.w
				end
				breathe()
			end
			if not complete then break end
		end
		if not complete then break end
	end
	rank()

	-- refine around the best few: a third of a step either side
	if complete and q.refine > 0 then
		local step = 2 * math.pi / q.dirs
		local top = {}
		for i = 1, math.min(q.refine, #cands) do top[i] = cands[i] end
		for _, c in ipairs(top) do
			for _, k in ipairs({ -1, 1 }) do
				local n = { a = c.a + k * step / 3, s = 0, mg = 0, w = 0 }
				if not eval(n) then break end
				cands[#cands + 1] = n
			end
		end
		rank()
	end

	if not stillMine() then return end
	local best = cands[1]
	if not best or best.w <= 0 then return end
	local dir = dirOf(best.a)
	local path = lockDirection(m, dir)
	m.lastPred = score(best)
	STATE.lastAim = {
		deg = math.deg(angDiff(best.a, myBase)), pred = score(best), sims = sims,
		secs = os.clock() - t0, exact = exact, path = path or "failed", complete = complete,
		vs = ballName(m.oppRole), mine = ballName(m.myRole),
	}
	note(string.format("aim locked %+.1f deg, predicted %.0f%%", STATE.lastAim.deg, score(best) * 100))
end

--------------------------------------------------------------------------------
-- picking
--------------------------------------------------------------------------------

-- The opponent's pick is NOT visible before ours: the server keeps it out of
-- the state until both have picked (measured three times - their ball always
-- arrived in the same broadcast as ours, and Aiming followed at once). And
-- their last ball predicts little: 12 of 54 round changes kept it. So the pick
-- goes by the server's overall win rate, nudged by head-to-head against the
-- balls they have shown this match (their offers come from their collection),
-- and it goes quickly, because Picking ends the moment both have picked.
local function pickScore(role, seen)
	local g = winRate(role)
	if #seen == 0 then return g end
	local s = 0
	for _, o in ipairs(seen) do s = s + (h2h(role, o)) end
	return 0.6 * g + 0.4 * s / #seen
end

solvePick = function(model, data)
	if not (alive() and CONFIG.auto and CONFIG.smartPick) then return end
	if typeof(model) ~= "Instance" or type(data) ~= "table" then return end
	local offer = {}
	for _, r in pairs(type(data.offer) == "table" and data.offer or {}) do
		if type(r) == "string" then offer[#offer + 1] = r end
	end
	if #offer == 0 then return end
	STATE.phase = "picking"
	local m = M

	-- the free pick from the collection (selectPrice 0, once per match): ask
	-- for the list now, it costs nothing until a ball is confirmed from it
	local coll = nil
	if CONFIG.freePick and tonumber(data.selectPrice) == 0 and not (m and m.freeUsed) then
		fire("DuelTableBallSelectPurchase", model)
		local res = waitFor("DuelTableBallSelectPurchaseResult", function(mk) return mk == model end, 4)
		local list = res and type(res[2]) == "table" and res[2].roleIds
		if type(list) == "table" then
			coll = {}
			for _, r in pairs(list) do if type(r) == "string" then coll[#coll + 1] = r end end
		end
	end

	task.wait(RNG:NextNumber(0.8, 2))
	if not alive() or (m and M ~= m) then return end

	local seen = {}
	for _, r in ipairs(m and m.oppRoles or {}) do
		if not table.find(seen, r) then seen[#seen + 1] = r end
	end
	local cands = {}
	local function add(r, src)
		for _, c in ipairs(cands) do if c.role == r then return end end
		cands[#cands + 1] = { role = r, src = src, h = pickScore(r, seen) }
	end
	for _, r in ipairs(offer) do add(r, "offer") end
	for _, r in ipairs(coll or {}) do add(r, "collection") end
	table.sort(cands, function(x, y) return x.h > y.h end)
	local how = #seen > 0 and "win rate + head-to-head" or "win rate"

	-- the collection pick is spent only when it beats the best offered ball
	local bestOffer
	for _, c in ipairs(cands) do if c.src == "offer" then bestOffer = c break end end
	local choice = cands[1]
	if choice.src == "collection" and bestOffer and choice.h - bestOffer.h < 0.005 then choice = bestOffer end

	local via = "offer"
	if choice.src == "collection" then
		fire("DuelTableBallSelfSelect", model, choice.role)
		local okRes = waitFor("DuelTableBallSelectConfirmed", function(mk) return mk == model end, 3)
		if okRes then
			via = "collection"
			if m then m.freeUsed = true end
		else
			choice = bestOffer or cands[1]
		end
	end
	if via == "offer" then fire("DuelTableBallSelect", model, choice.role) end
	if m then m.pickedAt = serverNow() end
	STATE.lastPick = { role = choice.role, wr = choice.h, via = via, how = how }
	note(string.format("picked %s from the %s - %s %.1f%%", ballName(choice.role), via, how, choice.h * 100))
end

--------------------------------------------------------------------------------
-- upgrades
--------------------------------------------------------------------------------

local function cardStars(card)
	local defs = BC and (card.kind == "effect" and BC.traits
		or (BC.tournament_upgrade and BC.tournament_upgrade.basicStats)) or nil
	local eff = type(defs) == "table" and defs[card.id] or nil
	local key = (type(eff) == "table" and eff.cnId) or card.id
	local ch = Config.upgradeChoice and Config.upgradeChoice.byTargetCnId and Config.upgradeChoice.byTargetCnId[key]
	return ch and tonumber(ch.star) or 0, (type(eff) == "table" and (eff.displayName or eff.name)) or key
end

solveUpgrade = function(model, data)
	if not (alive() and CONFIG.auto and CONFIG.smartUpgrade) then return end
	if typeof(model) ~= "Instance" or type(data) ~= "table" then return end
	local cards = {}
	for _, c in pairs(type(data.offer) == "table" and data.offer or {}) do
		if type(c) == "table" and type(c.id) == "string" and (c.kind == "effect" or c.kind == "basicStat") then
			cards[#cards + 1] = { kind = c.kind, id = c.id, s = 0, w = 0 }
		end
	end
	if #cards == 0 then return end
	STATE.phase = "upgrading"
	local m = M
	local how = "stars"

	-- Simulated: last round's balls on next round's seed (exact when known)
	-- plus sampled ones, our arrow and the opponent's - with and without each
	-- card. The balls will change at the next pick, so this is a proxy, which
	-- is why a near-tie goes to the card's star rating instead.
	if m and m.lastOpts and m.opp and BS and BC then
		local o = m.lastOpts
		local seeds = {}
		if m.seedBase and m.seedOk then seeds[1] = m.seedBase + m.round * SEED_STEP end
		while #seeds < 4 do seeds[#seeds + 1] = math.floor(serverNow() * 1000) - RNG:NextInteger(0, 90000) end
		local myD = { m.myDir or towardEnemy(m.team, m.opp), towardEnemy(m.team, m.opp) }
		local opD = { m.oppDirs[#m.oppDirs] or towardEnemy(m.opp, m.team), towardEnemy(m.opp, m.team) }
		local stopAt = os.clock() + math.max(3, math.min(9, (tonumber(data.duration) or 20) - 8))
		frameStart = os.clock()
		for _, c in ipairs(cards) do
			local stats, traits = currentStatsTraits(m)
			applyCard(c, stats, traits, m.team)
			for _, seed in ipairs(seeds) do
				for _, a in ipairs(myD) do
					for _, b in ipairs(opD) do
						if os.clock() > stopAt or not alive() then break end
						local ok, st = pcall(simulate, seed, o.selectedRoles, traits, stats, { [m.team] = a, [m.opp] = b })
						if ok and st then
							local s = outcome(st, m.team, m.opp)
							c.s, c.w = c.s + s, c.w + 1
						end
						breathe()
					end
				end
			end
		end
		how = "simulated"
	end

	for _, c in ipairs(cards) do c.star = cardStars(c) end
	table.sort(cards, function(x, y)
		local sx, sy = x.w > 0 and x.s / x.w or 0, y.w > 0 and y.s / y.w or 0
		if math.abs(sx - sy) > 0.03 then return sx > sy end
		return (x.star or 0) > (y.star or 0)
	end)
	local best = cards[1]
	if not alive() then return end
	fire("DuelTableUpgradeSelect", model, { kind = best.kind, id = best.id })
	if m then m.pendingCard = { kind = best.kind, id = best.id } end
	local _, label = cardStars(best)
	STATE.lastUpgrade = { label = tostring(label), how = how, pred = best.w > 0 and best.s / best.w or nil }
	note("upgrade: " .. tostring(label))
end

--------------------------------------------------------------------------------
-- events
--------------------------------------------------------------------------------

on("DuelTableState", onState)
on("DuelTableReplayStream", onReplay)
on("DuelTableBallOffer", function(model, data)
	task.spawn(function()
		local ok, err = pcall(solvePick, model, data)
		if not ok then note("pick: " .. tostring(err)) end
	end)
end)
on("DuelTableUpgradeOffer", function(model, data)
	task.spawn(function()
		local ok, err = pcall(solveUpgrade, model, data)
		if not ok then note("upgrade: " .. tostring(err)) end
	end)
end)
on("DuelTableBallSelectPurchaseResult")
on("DuelTableBallSelectConfirmed")
on("DuelTableBallSelectConfirmDenied")
on("DuelTableBallLocked")
on("DuelTableLaunchLocked")
on("DuelTableUpgradeLocked")
on("DuelQuickPlayResult")
on("CurrencyChanged", function(cur, delta, _, src)
	if cur == "coins" and type(src) == "table" and src.type == "duelReward" then
		STATE.coinsEarned = STATE.coinsEarned + (tonumber(delta) or 0)
	end
end)
on("DuelCoinLimitReached", function() note("daily duel coin cap reached - duels still give EXP and quest progress") end)

--------------------------------------------------------------------------------
-- loops
--------------------------------------------------------------------------------

local function loop(sec, fn)
	task.spawn(function()
		while alive() do
			local ok, err = pcall(fn)
			if not ok then note(tostring(err)) end
			task.wait(sec)
		end
	end)
end

local ACTIVE = { Picking = true, Aiming = true, RoundStarting = true, Playing = true, Upgrading = true }
local function inMatch() return M ~= nil and ACTIVE[M.state or ""] == true end

-- seat: quick play whenever we are not at a table, and walk away from a table
-- nobody joins
do
	local lastQuick, lastLeave = -1e9, -1e9
	loop(1, function()
		if not (CONFIG.auto and CONFIG.autoQueue) then return end
		local seated = plr:GetAttribute("InDuelTable") == true
		if not seated then
			if not inMatch() then STATE.phase = "queueing" end
			if os.clock() - lastQuick > 8 then
				lastQuick = os.clock()
				fire("DuelQuickPlayRequest")
				STATE.queues = STATE.queues + 1
			end
		elseif M and M.state == "Waiting" and M.aloneSince and CONFIG.leaveEmpty > 0
			and os.clock() - M.aloneSince > CONFIG.leaveEmpty and os.clock() - lastLeave > 30 then
			lastLeave = os.clock()
			M.aloneSince = nil
			fire("DuelTableLeaveRequest")
			note("nobody joined for " .. CONFIG.leaveEmpty .. "s - looking for another table")
		elseif M and not inMatch() then
			STATE.phase = M.state == "Waiting" and "waiting for an opponent" or tostring(M.state):lower()
		end
	end)
end

-- the win-rate table, once at start and every ten minutes
loop(30, function() refreshStats(false) end)

-- rewards: online timer, daily quests, mail, check-in, codes
do
	local tried = {}
	local mailQuietUntil = 0
	loop(15, function()
		if not (CONFIG.auto and CONFIG.rewards) then return end
		local X = D()
		local on = type(X.onlineReward) == "table" and X.onlineReward or {}
		local claimed = type(on.claimed) == "table" and on.claimed or {}
		for _, tier in ipairs(ORC and ORC.getTiers and ORC.getTiers() or {}) do
			local key = "online" .. tostring(on.dayKey) .. ":" .. tostring(tier.index)
			if (tonumber(on.onlineSeconds) or 0) >= (tonumber(tier.seconds) or 1e9)
				and not claimed[tostring(tier.index)] and not tried[key] then
				tried[key] = true
				local r = invoke("OnlineRewardClaim", tier.index)
				if type(r) == "table" and r.ok then
					STATE.rewards = STATE.rewards + 1
					note("online reward " .. tostring(tier.index) .. " claimed")
				end
				task.wait(1)
			end
		end

		local dq = type(X.dailyQuest) == "table" and X.dailyQuest or {}
		for _, qd in ipairs(Config.dailyQuest and Config.dailyQuest.list or {}) do
			local prog = dq.progress and tonumber(dq.progress[qd.cnId]) or 0
			local key = "quest" .. tostring(dq.dayKey) .. ":" .. tostring(qd.cnId)
			if prog >= (tonumber(qd.requireCount) or 1e9) and not (dq.claimed and dq.claimed[qd.cnId]) and not tried[key] then
				tried[key] = true
				local r = invoke("DailyQuestClaim", qd.cnId)
				if type(r) == "table" and r.ok then
					STATE.rewards = STATE.rewards + 1
					note("quest '" .. tostring(qd.desc) .. "' claimed, +" .. tostring(r.rewardCoins) .. " coins")
				end
				task.wait(1)
			end
		end

		if os.clock() > mailQuietUntil then
			local any = false
			for _, mail in pairs(X.mailbox and X.mailbox.mails or {}) do
				if type(mail) == "table" and (tonumber(mail.claimedAt) or 0) <= 0 then any = true break end
			end
			if any then
				local r = invoke("MailService/Claim", "ALL")
				if type(r) == "table" and (tonumber(r.claimed) or 0) > 0 then
					STATE.rewards = STATE.rewards + r.claimed
					note("mail: " .. tostring(r.claimed) .. " claimed")
				else
					mailQuietUntil = os.clock() + 600
				end
			end
		end

		local ci = type(X.checkIn) == "table" and X.checkIn or {}
		local cc = type(ci.claimed) == "table" and ci.claimed or {}
		for i = 1, tonumber(ci.progressDays) or 0 do
			local key = "checkin" .. tostring(ci.lastDayKey) .. ":" .. i
			if not (cc[i] or cc[tostring(i)]) and not tried[key] and rf("CheckInClaim") then
				tried[key] = true
				local r = invoke("CheckInClaim", i)
				if type(r) == "table" and r.ok then
					STATE.rewards = STATE.rewards + 1
					note("check-in day " .. i .. " claimed")
				end
				task.wait(1)
			end
		end

		if CONFIG.codes then
			ENV.__BVB_CODES = ENV.__BVB_CODES or {}
			local done = ENV.__BVB_CODES
			local list = type(Config.codes) == "table" and (Config.codes.list or Config.codes) or {}
			for _, c in pairs(list) do
				if type(c) == "table" and type(c.code) == "string" and not c.grantOnly and done[c.code] == nil then
					local r = invoke("RedeemCodeRedeem", c.code)
					done[c.code] = r ~= nil and tostring(type(r) == "table" and (r.status or r.result or r.reason or r.ok) or r) or false
					if r == "SUCCESS" or (type(r) == "table" and r.ok) then
						STATE.codes = STATE.codes + 1
						note("code " .. c.code .. " redeemed")
					end
					task.wait(2.5)
				end
			end
		end
	end)
end

-- Coins Ball Gacha: the only coin purchase that changes a fight. Not while a
-- match is running, so the reward popups never land on top of a pick.
do
	local CRATE = "金币小球箱子单抽"
	loop(3, function()
		if not (CONFIG.auto and CONFIG.buyBalls) or inMatch() then return end
		local c = Config.crate and Config.crate.byCnId and Config.crate.byCnId[CRATE]
		local price = c and tonumber(c.coinsPrice) or 600
		if price <= 0 or coins() < price + (tonumber(CONFIG.coinReserve) or 0) then return end
		local r = invoke("GachaRoll", CRATE, "coins")
		if type(r) == "table" and r.ok then
			STATE.rolls = STATE.rolls + 1
			-- a single draw copies its result onto the top level as well
			local got = type(r.results) == "table" and type(r.results[1]) == "table" and r.results[1] or r
			note("Coins Ball Gacha: " .. ballName(got.itemId or got.targetId or got.cnId))
		elseif type(r) == "table" then
			note("gacha: " .. tostring(r.reason))
			task.wait(10)
		end
	end)
end

-- anti-AFK: a long queue is still idle time to Roblox
pcall(function()
	local VU = game:GetService("VirtualUser")
	table.insert(ENV.__BVB_CONN, plr.Idled:Connect(function()
		if not alive() or not CONFIG.antiAfk then return end
		pcall(function() VU:CaptureController() VU:ClickButton2(Vector2.new()) end)
	end))
end)

-- Run by hand there is no hub to follow the game across its servers, so the
-- queue is armed here instead - gated on the place id, never another game.
do
	local hubOwns = _G.__SEL and _G.__SEL.game and _G.__SEL.game.alias == "ballvsball"
	if not hubOwns and not ENV.__BVB_QUEUED then
		local q = queue_on_teleport or (syn and syn.queue_on_teleport)
		if q then
			ENV.__BVB_QUEUED = true
			pcall(q, "if game.PlaceId ~= " .. PLACE .. " then return end "
				.. "if isfile and isfile('ballvsball.lua') then loadstring(readfile('ballvsball.lua'))() end")
		end
	end
end

--------------------------------------------------------------------------------
-- panel
--------------------------------------------------------------------------------

local UI = (_G.__SEL and _G.__SEL.ui) or loadstring(readfile("ui-template.lua"))()
if ENV.__BVB_WIN then pcall(function() ENV.__BVB_WIN:Destroy() end) end
if UI.sweep then UI.sweep("SeluxBallVsBallPanel") end
UI.config("ballvsball", CONFIG)

local win = UI.Window({
	name = "SeluxBallVsBallPanel", title = "BALL VS", accentTitle = "BALL", subtitle = "seltonmt",
})
ENV.__BVB_WIN = win

local statusOut
do
	local page = win:Page("DUEL", UI.icon and (UI.icon.target or UI.icon.sword) or nil)
	local duel = page:Card("FIGHT", 1):Accent()
	duel:Toggle("Smart aim", CONFIG.smartAim, function(v) CONFIG.smartAim = v end,
		"plays the round out in the game's own simulation for every arrow and locks the best one")
	duel:Dropdown("Aim quality", { "Fast", "Normal", "Best" }, CONFIG.aimQuality,
		function(v) CONFIG.aimQuality = v end)
	duel:Toggle("Smart ball pick", CONFIG.smartPick, function(v) CONFIG.smartPick = v end,
		"the ball with the best win rate in the server's own statistics")
	duel:Toggle("Use the free pick from the collection", CONFIG.freePick, function(v) CONFIG.freePick = v end,
		"once per match, only when it is free and only for a better ball than the offer")
	duel:Toggle("Smart upgrade cards", CONFIG.smartUpgrade, function(v) CONFIG.smartUpgrade = v end,
		"simulates each card; a near-tie goes to the card's star rating")

	local seat = page:Card("TABLE", 2)
	seat:Toggle("Join tables by itself", CONFIG.autoQueue, function(v) CONFIG.autoQueue = v end,
		"the game's own quick play, every 8 s while not seated")
	seat:Slider("Leave an empty table after (s)", 0, 180, CONFIG.leaveEmpty,
		function(v) CONFIG.leaveEmpty = v end, "0 stays seated until someone comes")
	seat:Toggle("Anti-AFK", CONFIG.antiAfk, function(v) CONFIG.antiAfk = v end)

	local rew = page:Card("REWARDS", 2)
	rew:Toggle("Claim rewards", CONFIG.rewards, function(v) CONFIG.rewards = v end,
		"online timer, daily quests, mail and check-in")
	rew:Toggle("Redeem codes", CONFIG.codes, function(v) CONFIG.codes = v end,
		"every code in the game's own list, once")
	rew:Toggle("Buy balls with coins", CONFIG.buyBalls, function(v) CONFIG.buyBalls = v end,
		"Coins Ball Gacha, 600 coins - never diamonds, never Robux")
	rew:Slider("Keep coins in reserve", 0, 6000, CONFIG.coinReserve,
		function(v) CONFIG.coinReserve = v end)

	statusOut = page:Card("STATUS", 0):Readout(9)
end

win:Home()
pcall(function()
	win:SetMaster(CONFIG.auto, "Auto duel running")
	win:OnMaster(function(on) CONFIG.auto = on end)
end)

local function fmt(n)
	n = tonumber(n) or 0
	local s = tostring(math.floor(n))
	local k
	repeat s, k = s:gsub("^(-?%d+)(%d%d%d)", "%1,%2") until k == 0
	return s
end

task.spawn(function()
	while alive() do
		pcall(function()
			local X = D()
			local lim = type(X.duelCoinLimit) == "table" and X.duelCoinLimit or {}
			local cap = Config.misc and Config.misc.coinsLimit and tonumber(Config.misc.coinsLimit["每日金币上限"]) or 6000
			local owned = ownedBalls()
			local tbl = "not seated"
			local opp = "-"
			if M then
				local myHp = M.hp and M.hp[tostring(UID)] or M.hp and M.hp[UID]
				local opHp = M.oppUid and M.hp and (M.hp[tostring(M.oppUid)] or M.hp[M.oppUid])
				tbl = string.format("%s  %s  round %d  hearts %s:%s", tostring(M.tableId), tostring(M.state),
					(M.round or 0) + ((M.state == "Picking" or M.state == "Aiming") and 1 or 0),
					tostring(myHp or "-"), tostring(opHp or "-"))
				if M.oppUid then
					local p = Players:GetPlayerByUserId(M.oppUid)
					opp = (p and p.Name or tostring(M.oppUid)) .. (M.oppRole and ("  " .. ballName(M.oppRole)
						.. string.format(" (%.1f%%)", winRate(M.oppRole) * 100)) or "")
						.. (M.oppAfk and "  AFK - timed out on the pick" or "")
				end
			end
			local a = STATE.lastAim
			local aim = a and string.format("%+.1f deg  %s vs %s  predicted %.0f%%  %s, %d sims in %.1fs%s  via %s",
				a.deg, a.mine, a.vs, a.pred * 100, a.exact and "exact seed" or "sampled seeds", a.sims, a.secs,
				a.complete and "" or " (cut short)", a.path) or "-"
			local pk = STATE.lastPick
			local pick = pk and string.format("%s from the %s, %s %.1f%%", ballName(pk.role), pk.via,
				pk.how or "win rate", pk.wr * 100) or "-"
			local up = STATE.lastUpgrade
			local upg = up and (up.label .. "  " .. up.how .. (up.pred and string.format(" %.0f%%", up.pred * 100) or "")) or "-"
			statusOut:set({
				"phase     " .. STATE.phase,
				"table     " .. tbl,
				"opponent  " .. opp,
				"aim       " .. aim,
				"pick      " .. pick .. "   upgrade " .. upg,
				string.format("session   matches %d-%d   rounds %d-%d-%d   seed %d/%d   sim parity %d/%d",
					STATE.matchWins, STATE.matchLosses, STATE.roundWins, STATE.roundLosses, STATE.roundDraws,
					STATE.seedHits, STATE.seedHits + STATE.seedMiss, STATE.parityHits, STATE.parityHits + STATE.parityMiss),
				string.format("coins     %s   duel cap today %s/%s   earned %s   diamonds %s",
					fmt(coins()), fmt(lim.dailyEarned), fmt(cap), fmt(STATE.coinsEarned), fmt(diamonds())),
				string.format("balls     %d owned   rolled %d   rewards %d   codes %d", owned, STATE.rolls, STATE.rewards, STATE.codes),
				"note      " .. STATE.note,
			})
			win:SetStat(1, fmt(coins()), "coins")
			win:SetStat(2, STATE.matchWins .. "-" .. STATE.matchLosses, "matches")
			win:SetStat(3, STATE.roundWins .. "-" .. STATE.roundLosses, "rounds")
		end)
		task.wait(0.5)
	end
end)

ENV.__BVB_DBG = {
	CONFIG = CONFIG, STATE = STATE, WR = WR, getMatch = function() return M end,
	simulate = simulate, solveAim = solveAim, solvePick = solvePick, solveUpgrade = solveUpgrade,
	refreshStats = refreshStats, winRate = winRate, aimClient = aimClient, invoke = invoke, fire = fire,
}

fire("DuelTableStateRequest")
print("[selux ballvsball] gen " .. GEN .. " ready - RightShift for the panel")
