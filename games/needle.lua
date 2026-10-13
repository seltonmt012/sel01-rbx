--[[ needle.lua - [🎃] Search For The Needle (Garage Games)

  Lobby 77108422251420 and one place per map: Farmhouse 108628039999641,
  Basement 83445806734780, Ranch 82626725163709, Graveyard 102537610748607.
  One file for all of them; it works out which side it is on by what the place
  exposes. Measured 2026-10-13 - see games-collect.md "needle" for the numbers.

  The loop: lobby pad -> CreateParty -> the map place -> dig the pile evenly,
  sell at the cow, buy the cash upgrades and TNT -> the server reveals the
  needle (NeedleTargetChanged) -> dig it free, pick "Objective", hand it to the
  farmer -> replay or back to the lobby, gem upgrades, next run.
]]

local Players    = game:GetService("Players")
local RS         = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local CS         = game:GetService("CollectionService")

-- The teleport queue starts this before the place has loaded, and then
-- LocalPlayer is still nil: measured after a replay, the map loop died on its
-- first attribute read. Wait for both.
if not game:IsLoaded() then game.Loaded:Wait() end
local plr = Players.LocalPlayer
while not plr do
	task.wait(0.1)
	plr = Players.LocalPlayer
end

local LOBBY_PLACE = 77108422251420
local MAP_PLACES = {
	[108628039999641] = "FARMHOUSE", [83445806734780] = "BASEMENT",
	[82626725163709] = "RANCH", [102537610748607] = "GRAVEYARD",
}

-- Everything of ours lives in getgenv(): with a rejoin it is gone anyway, and
-- the game has no path to it.
local ENV
do
	local ok, g = pcall(function() return getgenv() end)
	ENV = (ok and type(g) == "table") and g or _G
end
ENV.__NEEDLE = (ENV.__NEEDLE or 0) + 1
local GEN = ENV.__NEEDLE
local function alive() return ENV.__NEEDLE == GEN end

local NH = RS:FindFirstChild("NeedleHaystack")
local IN_MAP = NH ~= nil or MAP_PLACES[game.PlaceId] ~= nil
if IN_MAP and not NH then NH = RS:WaitForChild("NeedleHaystack", 30) end
local IN_LOBBY = not IN_MAP

--------------------------------------------------------------------------------
-- config and state
--------------------------------------------------------------------------------

local CONFIG = {
	auto       = false,       -- the master switch: everything below only acts while on
	-- lobby
	autoStart  = true,        -- start a run from the lobby by itself
	map        = "FARMHOUSE",
	difficulty = "NORMAL",
	gemUpgrades = true,       -- spend gems on the lobby upgrades
	-- map
	farm       = true,
	autoSell   = true,
	sellAt     = 100,         -- per cent of the bag
	-- The needle shows when 75% of ALL the hay is gone (measured: revealed at
	-- 24,112 of 100,000), wherever it was dug - so nearest first wins: 66
	-- strands a second against 59 with the even spread and its moves.
	evenDig    = false,
	rareFirst  = true,
	cashUpgrades = true,
	buyTnt     = true,        -- and the other tools: TNT, pitchfork, vacuum
	useTnt     = true,
	useFork    = true,        -- the pitchfork alongside the hand, separate cooldowns
	useVacuum  = true,        -- the vacuum while it is cold, ~30 strands a second
	vacPulse   = true,        -- switch it on for one frame per tick: a sixth of the heat
	gems       = true,
	needle     = true,
	afterWin   = "Auto",      -- Auto | Replay | Lobby | Stay
	antiAfk    = true,
}

local STATE = {
	phase = "starting", note = "", picks = 0, credited = 0, sells = 0, earned = 0,
	moves = 0, upgrades = 0, tnts = 0, gems = 0, needleId = nil, needleSeen = 0,
	wins = 0, runs = 0, rate = 0, lastWinAt = 0,
}

local function note(s) STATE.note = tostring(s) end

local function attr(name, default)
	local v = plr:GetAttribute(name)
	if v == nil then return default end
	return v
end

local function cash()
	local ls = plr:FindFirstChild("leaderstats")
	local c = ls and ls:FindFirstChild("Cash")
	return (c and tonumber(c.Value)) or 0
end

local function wins()
	local ls = plr:FindFirstChild("leaderstats")
	local w = ls and ls:FindFirstChild("Wins")
	return (w and tonumber(w.Value)) or 0
end

local function root()
	local c = plr.Character
	return c and c:FindFirstChild("HumanoidRootPart")
end

local function settle(frames)
	for _ = 1, frames or 2 do RunService.Heartbeat:Wait() end
end

-- Pin the body to a spot for a while. A single CFrame write is not enough for
-- anything the server measures against its own copy of the position, so the
-- write is repeated every Heartbeat for the hold.
local function hold(cf, seconds)
	local r = root()
	if not r then return false end
	local untilT = os.clock() + (seconds or 0)
	repeat
		r.CFrame = cf
		pcall(function() r.AssemblyLinearVelocity = Vector3.zero end)
		RunService.Heartbeat:Wait()
	until os.clock() >= untilT or not alive()
	return true
end

--------------------------------------------------------------------------------
-- the map: digging, selling, upgrades, the needle
--------------------------------------------------------------------------------

local mapLoop, lobbyLoop
local Config = {}
local R = {}

if IN_MAP and NH then
	pcall(function() Config = require(NH:WaitForChild("Config", 10)) end)
	for _, n in ipairs({ "PickHay", "SellHay", "BuyShopItem", "BuyUpgrade", "TntAction",
		"CollectGem", "NeedleHandIn", "NeedleTargetChanged", "ReplayVote", "ReturnToLobby",
		"GetHayState", "NeedleRoundCompleted", "HaySold" }) do
		R[n] = NH:FindFirstChild(n)
	end
end

do
	local HAY_VALUE = tonumber(Config.HAY_VALUE) or 0.01
	local GRID = tonumber(Config.DIG_GRID_RESOLUTION) or 31
	local PILE_R = tonumber(Config.PILE_RADIUS) or 17
	local KERNEL = tonumber(Config.DIG_KERNEL_RADIUS) or 2.55
	local REACH = math.max(8, (tonumber(Config.INTERACT_DISTANCE) or 20) - 2.5)
	local CENTER = typeof(Config.PILE_CENTER) == "Vector3" and Config.PILE_CENTER or Vector3.new(-199.18, 2.1, 30.24)
	-- THE SERVER'S GRID IS WIDER THAN THE PILE. Measured: one pick at (+11.1,
	-- -7.3) from the centre raised cell 334 (ix 23, iz 10, row-major in z), and
	-- that only lands on the strand with a half-extent of ~22 studs on both axes
	-- - PILE_RADIUS + 2 x DIG_KERNEL_RADIUS, so a dig at the rim still has cells
	-- to fall into. Assuming the pile radius put every lookup ~3 studs off.
	local EXTENT = PILE_R + 2 * KERNEL
	local CELL = EXTENT * 2 / GRID

	local mutationValue = {}
	for _, m in ipairs(type(Config.HAY_MUTATIONS) == "table" and Config.HAY_MUTATIONS or {}) do
		if type(m) == "table" and m.Name then mutationValue[tostring(m.Name)] = tonumber(m.ValueMultiplier) or 1 end
	end

	-- OUR OWN MAP OF HOW DEEP EACH CELL IS DUG. The server keeps the same 31x31
	-- grid (GetHayState().dig) and reveals the needle once the cell over it is
	-- dug to NEEDLE_REVEAL_FRACTION of its depth - so the fastest way to find a
	-- needle whose cell is unknown is to lower the whole pile evenly. Synced from
	-- the server every 20 s; between syncs every pick adds its kernel here.
	local depth = {}
	for i = 1, GRID * GRID do depth[i] = 0 end
	local function cellOf(pos)
		local ix = math.floor((pos.X - (CENTER.X - EXTENT)) / CELL)
		local iz = math.floor((pos.Z - (CENTER.Z - EXTENT)) / CELL)
		if ix < 0 or iz < 0 or ix >= GRID or iz >= GRID then return nil end
		return iz * GRID + ix + 1, ix, iz
	end
	local function addKernel(pos, amount)
		local _, cx, cz = cellOf(pos)
		if not cx then return end
		local span = math.ceil(KERNEL / CELL)
		for dz = -span, span do
			for dx = -span, span do
				local ix, iz = cx + dx, cz + dz
				if ix >= 0 and iz >= 0 and ix < GRID and iz < GRID then
					local d = math.sqrt(dx * dx + dz * dz) * CELL
					if d <= KERNEL then
						local i = iz * GRID + ix + 1
						depth[i] = depth[i] + amount * (1 - d / KERNEL)
					end
				end
			end
		end
	end
	local lastSync = 0
	local function syncDepth(force)
		if not R.GetHayState then return end
		if not force and os.clock() - lastSync < 20 then return end
		lastSync = os.clock()
		local ok, st = pcall(function() return R.GetHayState:InvokeServer() end)
		if ok and type(st) == "table" and type(st.dig) == "table" then
			for i = 1, GRID * GRID do
				local v = tonumber(st.dig[i])
				if v then depth[i] = v end
			end
			if st.needleRevealed and STATE.needleId == nil then note("server says the needle is revealed") end
		end
	end

	-- The game's own neighbour picker, found once: PickHay's second argument is
	-- the list of extra strands the hand takes, and it is capped by the grab
	-- upgrades. Ours is the fallback.
	local gameGrab
	if IN_MAP then pcall(function()
		for _, f in ipairs(getgc(false)) do
			if type(f) == "function" and islclosure(f) and debug.getinfo(f).name == "getGrabCandidates" then
				gameGrab = f
				break
			end
		end
	end) end
	local function grabList(piece)
		if gameGrab then
			local ok, list = pcall(gameGrab, piece)
			if ok and type(list) == "table" then return list end
		end
		local count = tonumber(attr("HayGrabCount", 1)) or 1
		local radius = tonumber(attr("HayGrabRadius", 0)) or 0
		local list = {}
		if count <= 1 or radius <= 0 then return list end
		local ok, parts = pcall(function() return workspace:GetPartBoundsInRadius(piece.Position, radius) end)
		if not ok then return list end
		for _, p in ipairs(parts) do
			local id = p:GetAttribute("HayId")
			if id and p ~= piece and p.Parent == piece.Parent then
				list[#list + 1] = id
				if #list >= count - 1 then break end
			end
		end
		return list
	end

	local recent = {}
	local function hayFolder() return workspace:FindFirstChild("HaystackClient") end

	-- Which strand next. Even digging: the lowest-dug cell wins, a rare strand
	-- gets a head start, and one within reach of where we stand beats a slightly
	-- better one across the pile - a move costs a settle, a pick does not.
	local function chooseTarget(reach)
		reach = reach or REACH
		local hc, r = hayFolder(), root()
		if not (hc and r) then return nil end
		local me, now = r.Position, os.clock()
		local best, bestScore
		for _, piece in ipairs(hc:GetChildren()) do
			local id = piece:GetAttribute("HayId")
			if id and not (recent[id] and now - recent[id] < 4) then
				local pos = piece.Position
				local dist = (pos - me).Magnitude
				local score
				if CONFIG.evenDig then
					local i = cellOf(pos)
					score = (i and depth[i] or 9) * 40
				else
					score = 0
				end
				-- a strand out of reach costs a move and a settle; worth it only
				-- for a cell clearly less dug than anything at hand
				score = score + dist * 0.02 + (dist > reach and 3 or 0)
				if CONFIG.rareFirst then
					local mult = mutationValue[tostring(piece:GetAttribute("HayMutation"))]
					if mult and mult > 1.5 then score = score - mult * 2 end
				end
				if not bestScore or score < bestScore then best, bestScore = piece, score end
			end
		end
		return best
	end

	local function standNear(pos, reach)
		local r = root()
		if not r then return false end
		if (r.Position - pos).Magnitude <= (reach or REACH) then return true end
		local out = Vector3.new(pos.X - CENTER.X, 0, pos.Z - CENTER.Z)
		out = out.Magnitude > 0.1 and out.Unit or Vector3.new(0, 0, 1)
		local spot = pos + out * 4 + Vector3.new(0, 4, 0)
		STATE.moves = STATE.moves + 1
		hold(CFrame.new(spot, Vector3.new(pos.X, spot.Y, pos.Z)), 0.25)
		return true
	end

	local function pickPiece(piece)
		local id = piece and piece:GetAttribute("HayId")
		if not id then return false end
		recent[id] = os.clock()
		local list = grabList(piece)
		local ok = pcall(function() R.PickHay:FireServer(id, list) end)
		if ok then
			STATE.picks = STATE.picks + 1
			addKernel(piece.Position, (tonumber(Config.DIG_DEPTH_PER_PICK) or 0.045) * (1 + #list))
		end
		return ok
	end

	local function pickDelay()
		return (tonumber(attr("HayPickCooldown", nil)) or tonumber(Config.PICK_COOLDOWN) or 0.55) + 0.04
	end

	local function bagFull()
		local held = tonumber(attr("HayHeld", 0)) or 0
		if attr("InfiniteBagOwned", false) then return held >= 200 end
		local cap = tonumber(attr("HayCapacity", 25)) or 25
		return held >= math.max(1, math.floor(cap * math.clamp(CONFIG.sellAt, 10, 100) / 100))
	end

	-- SELLING IS POSITION GATED TO THE PART ITSELF. Fired from 41 studs and fired
	-- standing 6 studs in front of it with the camera aimed at it, SellHay did
	-- nothing; standing ON the SellPart it paid at once (4 strands -> $0.04) and
	-- the server answered with HaySold.
	local function sellParts()
		local list = {}
		for _, p in ipairs(CS:GetTagged(Config.SELL_PART_NAME or "SellPart")) do
			if p:IsA("BasePart") and p:IsDescendantOf(workspace) then list[#list + 1] = p end
		end
		local sm = workspace:FindFirstChild("SellModel")
		local sp = sm and sm:FindFirstChild("SellPart")
		if sp and sp:IsA("BasePart") then table.insert(list, 1, sp) end
		return list
	end

	local function sell()
		local held0 = tonumber(attr("HayHeld", 0)) or 0
		if held0 <= 0 then return true end
		local cash0 = cash()
		STATE.phase = "selling"
		for _, part in ipairs(sellParts()) do
			hold(CFrame.new(part.Position + Vector3.new(0, 3, 0)), 0.45)
			pcall(function() R.SellHay:FireServer() end)
			local t0 = os.clock()
			while os.clock() - t0 < 1.5 and (tonumber(attr("HayHeld", 0)) or 0) >= held0 do
				hold(CFrame.new(part.Position + Vector3.new(0, 3, 0)), 0.1)
			end
			if (tonumber(attr("HayHeld", 0)) or 0) < held0 then
				STATE.sells = STATE.sells + 1
				STATE.earned = STATE.earned + math.max(0, cash() - cash0)
				return true
			end
		end
		note("sell refused - bag still " .. tostring(attr("HayHeld", 0)))
		return false
	end

	-- CASH UPGRADES. Cheap and they compound: Speed and Grab double the rate for
	-- a quarter dollar each, Capacity halves the trips. TNT is saved for once the
	-- hand is decent, because one blast clears up to 600 strands.
	-- HandHold is left out on purpose: it lets a HUMAN hold the button instead of
	-- clicking, and a script that fires the remote gets nothing for its dollar.
	-- Speed and Grab multiply the dig rate and are never held back for TNT.
	local HAND_TRACKS = { "Speed", "Grab", "Capacity", "Value" }
	-- Capacity joins them once the fork digs alongside the hand: at ~29 strands
	-- a second a 150 bag was full every 5 s and the selling trips ate the rate.
	local CORE = { Speed = true, Grab = true, Capacity = true }
	local function nextCost(track)
		local t = type(Config.UPGRADE_TRACKS) == "table" and Config.UPGRADE_TRACKS[track]
		if not t or type(t.Levels) ~= "table" then return nil end
		local lvl = tonumber(attr("HayUpgrade" .. track, 1)) or 1
		local nxt = t.Levels[lvl + 1]
		if not nxt then return nil end
		return (tonumber(nxt.Cost) or 0) * (tonumber(Config.UPGRADE_COST_MULTIPLIER) or 1)
	end
	-- The tools, in the order they are worth buying. The fork first: $8 for ~14
	-- strands a second ON TOP of the hand. Then TNT: $25 for 150-278 strands
	-- every ~20 s, straight into the bag past its cap. The prices are the shop's
	-- own; InfiniteBag is a gamepass and never bought here.
	local TOOLS = {
		{ item = "Pitchfork", price = 8,     owned = "PitchforkOwned" },
		{ item = "Tnt",       price = 25,    owned = "TntOwned" },
		{ item = "Vacuum",    price = 69.99, owned = "VacuumOwned" },
	}
	local function nextTool()
		if not CONFIG.buyTnt then return nil end
		for _, t in ipairs(TOOLS) do
			if not attr(t.owned, false) then return t end
		end
		return nil
	end
	-- Every track the barn sells, per tool. ALL of them - the first build left
	-- the pitchfork's three out and bought one level per pass, so $132 sat in
	-- the bank next to a page of unbought upgrades (reported with a screenshot).
	local TOOL_TRACKS = {
		TntOwned       = { "TntCooldown", "TntPower", "TntLuck" },
		PitchforkOwned = { "Pitchfork", "PitchforkCooldown", "PitchforkHold" },
		DroneOwned     = { "DroneSpeed", "DroneGrab", "DroneCapacity" },
		VacuumOwned    = { "VacuumPower", "VacuumCooling", "VacuumRuntime" },
	}
	local function buyUpgrades()
		if not (CONFIG.cashUpgrades and R.BuyUpgrade) then return end
		local tracks = {}
		for _, t in ipairs(HAND_TRACKS) do tracks[#tracks + 1] = t end
		for owned, list in pairs(TOOL_TRACKS) do
			if attr(owned, false) then for _, t in ipairs(list) do tracks[#tracks + 1] = t end end
		end
		-- THE TOOL FIRST, and while one is still to buy only Speed, Grab and
		-- Capacity may spend below its price. Measured the other way round: $9.85
		-- in the bank, the $8 fork never bought - every pass the $0.50 drone levels
		-- went first, the server answered (false, "Pitchfork", "CASH"), and the
		-- fork waited all round. The starvation pattern from traps.md.
		local tool = nextTool()
		if tool and R.BuyShopItem and cash() >= tool.price then
			pcall(function() R.BuyShopItem:FireServer(tool.item) end)
			task.wait(0.5)
			if attr(tool.owned, false) then note("bought " .. tool.item) end
			tool = nextTool()
		end
		-- cheapest affordable level first, as many as the money covers
		for _ = 1, 24 do
			local best, bestCost
			for _, t in ipairs(tracks) do
				local c = nextCost(t)
				if c and (not bestCost or c < bestCost) then best, bestCost = t, c end
			end
			if not best then break end
			local reserve = (tool and not CORE[best]) and tool.price or 0
			if cash() < bestCost + reserve then
				-- a core level may still be affordable even if the cheapest is not
				local coreBest, coreCost
				for _, t in ipairs(tracks) do
					local c = CORE[t] and nextCost(t)
					if c and (not coreCost or c < coreCost) then coreBest, coreCost = t, c end
				end
				if not coreBest or cash() < coreCost then break end
				best, bestCost = coreBest, coreCost
			end
			local before = tonumber(attr("HayUpgrade" .. best, 1)) or 1
			pcall(function() R.BuyUpgrade:FireServer(best) end)
			local t0 = os.clock()
			while os.clock() - t0 < 1 and (tonumber(attr("HayUpgrade" .. best, 1)) or 1) <= before do task.wait(0.05) end
			if (tonumber(attr("HayUpgrade" .. best, 1)) or 1) > before then
				STATE.upgrades = STATE.upgrades + 1
				note("bought " .. best .. " " .. (before + 1))
			else
				-- refused: a track this map does not sell, or a level that does
				-- not exist - drop it for this pass rather than loop on it
				for i, t in ipairs(tracks) do if t == best then table.remove(tracks, i) break end end
			end
		end
		if tool and R.BuyShopItem and cash() >= tool.price then
			pcall(function() R.BuyShopItem:FireServer(tool.item) end)
			task.wait(0.5)
			if attr(tool.owned, false) then note("bought " .. tool.item) end
		end
		-- THE DRONE is priced in GEMS (40), and gems pile up from the strands and
		-- the needle (120 a win) - so it is the one tool money never competes for.
		-- Deployed it flies its own trips: harvest, fly to the cow, sell.
		if CONFIG.buyTnt and R.BuyShopItem and not attr("DroneOwned", false)
			and (tonumber(attr("Gems", 0)) or 0) >= 40 then
			pcall(function() R.BuyShopItem:FireServer("Drone") end)
			task.wait(0.5)
			if attr("DroneOwned", false) then note("bought the drone") end
		end
		if attr("DroneOwned", false) and not attr("DroneDeployed", false) and NH:FindFirstChild("DeployDrone") then
			pcall(function() NH.DeployDrone:FireServer() end)
		end
	end

	-- TNT: light, wait for the server's "lit", throw at the least dug part of the
	-- pile. One blast harvests up to TNT_HARVEST_SAFETY_CAP strands.
	local Hotbar
	pcall(function() Hotbar = require(plr.PlayerScripts:WaitForChild("HotbarSlots", 10)) end)
	local function equip(slot)
		if not Hotbar then return false end
		pcall(Hotbar.select, slot)
		local ok, now = pcall(Hotbar.getEquipped)
		return ok and now == slot
	end
	local tntLit, tntReadyAt = false, 0
	if R.TntAction then
		R.TntAction.OnClientEvent:Connect(function(state, value)
			if not alive() then return end
			if state == "lit" then
				tntLit = true
				tntReadyAt = os.clock() + (tonumber(attr("TntCooldown", nil)) or tonumber(Config.TNT_COOLDOWN) or 20) + 0.2
			elseif state == "denied" then
				tntReadyAt = os.clock() + (tonumber(value) or 2) + 0.2
			end
		end)
	end
	local function lowestCellPos()
		local best, bestD
		for i = 1, GRID * GRID do
			local ix, iz = (i - 1) % GRID, math.floor((i - 1) / GRID)
			local x = CENTER.X - EXTENT + (ix + 0.5) * CELL
			local z = CENTER.Z - EXTENT + (iz + 0.5) * CELL
			local rr = math.sqrt((x - CENTER.X) ^ 2 + (z - CENTER.Z) ^ 2)
			if rr < PILE_R - 3 and (not bestD or depth[i] < bestD) then best, bestD = Vector3.new(x, CENTER.Y, z), depth[i] end
		end
		return best
	end
	local function throwTnt()
		if not (CONFIG.useTnt and R.TntAction and attr("TntOwned", false)) then return false end
		if os.clock() < tntReadyAt then return false end
		local target = lowestCellPos()
		if not target then return false end
		local stand = target + Vector3.new(0, 14, 7)
		local face = CFrame.lookAt(stand, target)
		hold(face, 0.15)
		if not equip(tonumber(Config.TNT_SLOT_INDEX) or 2) then return false end
		settle(3)
		tntLit = false
		pcall(function() R.TntAction:FireServer("light") end)
		local t0 = os.clock()
		while not tntLit and os.clock() - t0 < 1.2 do hold(face, 0) end
		-- back to the fork when there is one, since the hand works with it held
		local backTo = (CONFIG.useFork and attr("PitchforkOwned", false)) and (tonumber(Config.PITCHFORK_SLOT_INDEX) or 3) or 1
		if not tntLit then
			if tntReadyAt < os.clock() then tntReadyAt = os.clock() + 3 end
			equip(backTo)
			return false
		end
		hold(face, (tonumber(Config.TNT_LIGHT_TIME) or 0.48) + 0.08)
		local vel = (target - stand).Unit * 22
		pcall(function() R.TntAction:FireServer("throw", face * CFrame.new(0, 1, -1), vel) end)
		STATE.tnts = STATE.tnts + 1
		addKernel(target, 1.2)
		task.wait(0.3)
		equip(backTo)
		return true
	end

	-- THE PITCHFORK RUNS ALONGSIDE THE HAND. Its cooldown is its own and a hand
	-- pick is accepted while the fork is the held tool, so the two are fired in
	-- the same loop. Measured: 3 swings alone took 36 strands (12 a swing); fork
	-- plus hand three times over took 49 - the hand's 5 on top of the fork's 12,
	-- every round. Every public script picks one tool or the other.
	local forkReadyAt = 0
	local function forkSlot() return tonumber(Config.PITCHFORK_SLOT_INDEX) or 3 end
	local function holdTool()
		if CONFIG.useFork and attr("PitchforkOwned", false) then equip(forkSlot()) else equip(1) end
	end
	local function forkStep()
		if not (CONFIG.useFork and attr("PitchforkOwned", false) and NH:FindFirstChild("PitchforkDig")) then return false end
		if os.clock() < forkReadyAt then return false end
		if Hotbar then
			local ok, cur = pcall(Hotbar.getEquipped)
			if ok and cur ~= forkSlot() then equip(forkSlot()) end
		end
		local target = chooseTarget()
		if not target then return false end
		local r = root()
		if r and (r.Position - target.Position).Magnitude > REACH then return false end
		local id = target:GetAttribute("HayId")
		recent[id] = os.clock()
		forkReadyAt = os.clock() + (tonumber(attr("PitchforkCooldown", nil)) or tonumber(Config.PITCHFORK_COOLDOWN) or 0.85) + 0.05
		local ok = pcall(function() NH.PitchforkDig:FireServer(id) end)
		if ok then
			STATE.forks = (STATE.forks or 0) + 1
			addKernel(target.Position, tonumber(Config.PITCHFORK_DIG_DEPTH) or 0.3)
		end
		return ok
	end

	-- THE VACUUM, while it is cold. Measured: 18 ticks in 3 s took 90 strands -
	-- 5 a tick at 0.16 s, ~30 a second, capped at VACUUM_GRAB_COUNT however many
	-- ids are sent, and a faked root position 45 studs out took nothing. It runs
	-- hot after VACUUM_HEAT_TIME (30 s) and is then locked for the cooldown, so
	-- the fork takes over until it is ready again. With the vacuum held the fork
	-- barely counts (vacuum + hand + fork took 109 against the vacuum's 90).
	local vacOn, vacLast = false, 0
	local function vacReady()
		return CONFIG.useVacuum and attr("VacuumOwned", false) and NH:FindFirstChild("VacuumAction")
			and attr("VacuumState", "Ready") ~= "Overheated" and not attr("VacuumOverheated", false)
	end
	local function stopVac()
		if vacOn then
			vacOn = false
			pcall(function() NH.VacuumAction:FireServer("Stop") end)
		end
	end
	local function vacuumStep(target)
		if not vacReady() then
			if vacOn then stopVac() holdTool() end
			return false
		end
		local slot = tonumber(Config.VACUUM_SLOT_INDEX) or 5
		if Hotbar then
			local ok, cur = pcall(Hotbar.getEquipped)
			if ok and cur ~= slot then equip(slot) end
		end
		local tick = tonumber(Config.VACUUM_TICK) or 0.16
		if os.clock() - vacLast < tick then return true end
		vacLast = os.clock()
		-- THE PULSE. Heat only builds while the vacuum is ACTIVE (Start..Stop) and
		-- never cools on a Stop - so a vacuum switched on for one frame per tick
		-- heats for one frame per tick. Measured over 3 s each: continuous suction
		-- +0.104 heat for 50 strands; Start, one Heartbeat, Tick, Stop +0.018
		-- heat for 45 - the same yield at a sixth of the heat, ~170 s to an
		-- overheat instead of 30. Start and Tick in the SAME frame is refused
		-- (+10 of 18), the one frame between them is what makes it count.
		if CONFIG.vacPulse then
			vacOn = false
			pcall(function() NH.VacuumAction:FireServer("Start") end)
			RunService.Heartbeat:Wait()
		elseif not vacOn then
			vacOn = true
			pcall(function() NH.VacuumAction:FireServer("Start") end)
		end
		local r = root()
		if not r then return true end
		local hc = hayFolder()
		local list = {}
		for _, p in ipairs(hc and hc:GetChildren() or {}) do
			local d = (p.Position - target.Position).Magnitude
			if d < 3.5 then list[#list + 1] = { p, d } end
		end
		table.sort(list, function(a, b) return a[2] < b[2] end)
		local ids = {}
		for i = 1, math.min(tonumber(Config.VACUUM_GRAB_COUNT) or 5, #list) do
			ids[i] = list[i][1]:GetAttribute("HayId")
			recent[ids[i]] = os.clock()
		end
		if #ids > 0 then
			pcall(function() NH.VacuumAction:FireServer("Tick", target.Position, r.Position, ids) end)
			STATE.vacs = (STATE.vacs or 0) + 1
			addKernel(target.Position, (tonumber(Config.VACUUM_DIG_DEPTH) or 0.11))
		end
		if CONFIG.vacPulse then pcall(function() NH.VacuumAction:FireServer("Stop") end) end
		return true
	end

	-- GEMS lie on the pile as their own models with a GemId.
	local gemSeen = {}
	local function collectGem()
		local folder = workspace:FindFirstChild("GemsClient")
		local r = root()
		if not (CONFIG.gems and folder and r and R.CollectGem) then return false end
		local now = os.clock()
		for _, m in ipairs(folder:GetChildren()) do
			local part = m:IsA("BasePart") and m or m:FindFirstChildWhichIsA("BasePart", true)
			local id = part and part:GetAttribute("GemId")
			if id and not (gemSeen[id] and now - gemSeen[id] < 5) then
				gemSeen[id] = now
				hold(CFrame.new(part.Position + Vector3.new(0, 2.5, 0)), 0.15)
				pcall(function() R.CollectGem:FireServer(id) end)
				STATE.gems = STATE.gems + 1
				return true
			end
		end
		return false
	end

	-- THE NEEDLE. The server announces the strand that hides it once the pile
	-- over it is dug far enough; digging around that strand turns one piece
	-- into the objective, which is picked with the literal "Objective".
	local needlePos
	local function pieceById(id)
		local hc = hayFolder()
		if not (hc and id) then return nil end
		for _, p in ipairs(hc:GetChildren()) do
			if p:GetAttribute("HayId") == id then return p end
		end
		return nil
	end
	local function findObjective()
		local hc = hayFolder()
		if not hc then return nil end
		for _, p in ipairs(hc:GetChildren()) do
			if p:GetAttribute("IsNeedleObjective") then return p end
		end
		return nil
	end
	if R.NeedleTargetChanged then
		R.NeedleTargetChanged.OnClientEvent:Connect(function(...)
			if not alive() then return end
			local args = { ... }
			for _, v in ipairs(args) do
				if type(v) == "number" and v % 1 == 0 then
					STATE.needleId = v
					STATE.needleSeen = os.clock()
					local p = pieceById(v)
					if p then needlePos = p.Position end
					note("needle revealed - strand " .. v)
					break
				end
			end
		end)
	end

	local function handIn()
		local npc = workspace:FindFirstChild("NPC")
		local farmer = npc and npc:FindFirstChild("Farmer_NPC")
		if not farmer then note("no farmer in this map") return false end
		STATE.phase = "handing in"
		equip(tonumber(Config.NEEDLE_SLOT_INDEX) or 4)
		local pv = farmer:GetPivot()
		for _ = 1, 6 do
			if not attr("NeedleOwned", false) then return true end
			hold(CFrame.lookAt(pv.Position + pv.LookVector * 5 + Vector3.new(0, 2, 0), pv.Position), 0.4)
			pcall(function() R.NeedleHandIn:FireServer() end)
			task.wait(1)
		end
		return not attr("NeedleOwned", false)
	end

	local function claimStep()
		local obj = findObjective()
		if obj then
			STATE.phase = "taking the needle"
			standNear(obj.Position)
			hold(CFrame.new(obj.Position + Vector3.new(0, 4, 2)), 0.2)
			pcall(function() R.PickHay:FireServer("Objective") end)
			task.wait(0.6)
			return true
		end
		local anchor = pieceById(STATE.needleId)
		if anchor then needlePos = anchor.Position end
		if not needlePos then return false end
		STATE.phase = "digging the needle out"
		local hc, best, bestD = hayFolder(), nil, nil
		local dig = tonumber(Config.NEEDLE_DIG_RADIUS) or 5.5
		for _, p in ipairs(hc and hc:GetChildren() or {}) do
			local id = p:GetAttribute("HayId")
			if id and not (recent[id] and os.clock() - recent[id] < 3) then
				local d = (p.Position - needlePos).Magnitude
				if d <= dig and (not bestD or d < bestD) then best, bestD = p, d end
			end
		end
		if best then
			standNear(best.Position)
			pickPiece(best)
		end
		return true
	end

	local roundDoneHandled = false
	local function afterRound()
		if roundDoneHandled then return end
		if not attr("NeedleRoundComplete", false) then return end
		roundDoneHandled = true
		STATE.wins = STATE.wins + 1
		STATE.lastWinAt = os.clock()
		STATE.phase = "round complete"
		task.wait(4)
		local mode = CONFIG.afterWin
		if mode == "Auto" then
			-- the lobby only when there is something to buy there: everything
			-- bought in the map is gone next round, only gem upgrades stay
			local cheapest
			pcall(function()
				local UC = require(RS.Shared.Configs.UpgradeConfig)
				for _, u in ipairs(UC.Upgrades) do
					local lvl = tonumber(plr:GetAttribute("Upgrade" .. tostring(u.DataKey or u.Id))) or 0
					local price = u.Prices and u.Prices[lvl + 1]
					if price and (not cheapest or price < cheapest) then cheapest = price end
				end
			end)
			local gems = tonumber(attr("Gems", 0)) or 0
			mode = (CONFIG.gemUpgrades and cheapest and gems >= cheapest) and "Lobby" or "Replay"
		end
		if mode == "Lobby" and R.ReturnToLobby then
			note("round complete - back to the lobby")
			pcall(function() R.ReturnToLobby:FireServer() end)
		elseif mode == "Replay" and R.ReplayVote then
			note("round complete - voting replay")
			pcall(function() R.ReplayVote:FireServer(true) end)
		end
	end

	local handReadyAt = 0
	function mapLoop()
		syncDepth(true)
		holdTool()
		local lastRate, lastHeld = os.clock(), tonumber(attr("HayHeld", 0)) or 0
		local creditWindow = 0
		while alive() do
			local ok, err = pcall(function()
				if not CONFIG.auto then
					STATE.phase = "idle (master switch off)"
					task.wait(0.5)
					return
				end
				if attr("NeedleRoundComplete", false) then stopVac() afterRound() task.wait(1) return end
				if attr("NeedleInputLocked", false) then stopVac() STATE.phase = "cutscene" task.wait(0.5) return end
				if CONFIG.needle and attr("NeedleOwned", false) then stopVac() handIn() return end
				if CONFIG.autoSell and bagFull() then stopVac() sell() buyUpgrades() holdTool() return end
				if CONFIG.needle and (STATE.needleId or findObjective()) then
					stopVac()
					if claimStep() then task.wait(pickDelay()) return end
				end
				if not CONFIG.farm then stopVac() STATE.phase = "farm off" task.wait(0.5) return end
				if collectGem() then return end
				syncDepth(false)
				if os.clock() >= tntReadyAt and attr("TntOwned", false) and CONFIG.useTnt then
					stopVac()
					if throwTnt() then return end
				end
				-- the vacuum only reaches VACUUM_RANGE (11), the hand INTERACT_DISTANCE
				local reach = vacReady() and math.max(5, (tonumber(Config.VACUUM_RANGE) or 11) - 3) or nil
				local target = chooseTarget(reach)
				if not target then STATE.phase = "no strand in reach" task.wait(0.5) return end
				STATE.phase = vacOn and "digging (vacuum)" or "digging"
				standNear(target.Position, reach)
				-- the hand on its own cooldown, then the vacuum while it is cold,
				-- the fork while it is not
				if os.clock() >= handReadyAt then
					pickPiece(target)
					handReadyAt = os.clock() + pickDelay()
				end
				local vac = vacuumStep(target)
				if not vac then forkStep() end
				local nextAt = vac and (vacLast + (tonumber(Config.VACUUM_TICK) or 0.16)) or handReadyAt
				task.wait(math.clamp(nextAt - os.clock(), 0.03, 1))
				-- credited rate, off the bag counter the server keeps
				local held = tonumber(attr("HayHeld", 0)) or 0
				if held > lastHeld then creditWindow = creditWindow + (held - lastHeld) end
				lastHeld = held
				if os.clock() - lastRate >= 5 then
					STATE.rate = creditWindow / (os.clock() - lastRate)
					STATE.credited = STATE.credited + creditWindow
					creditWindow, lastRate = 0, os.clock()
					buyUpgrades()
				end
			end)
			if not ok then note("map: " .. tostring(err)) task.wait(1) end
		end
	end

	ENV.__NEEDLE_MAP = {
		chooseTarget = chooseTarget, pickPiece = pickPiece, sell = sell, buyUpgrades = buyUpgrades,
		throwTnt = throwTnt, collectGem = collectGem, handIn = handIn, claimStep = claimStep,
		syncDepth = syncDepth, depth = depth, cellOf = cellOf, nextCost = nextCost,
		findObjective = findObjective, lowestCellPos = lowestCellPos, grabList = grabList,
	}
end

--------------------------------------------------------------------------------
-- the lobby: gem upgrades and starting a run
--------------------------------------------------------------------------------

do
	local Networker = RS:FindFirstChild("Packages") and RS.Packages:FindFirstChild("Networker")
	local remotes = Networker and Networker:FindFirstChild("_remotes")
	local function net(service)
		local f = remotes and remotes:FindFirstChild(service)
		return f and f:FindFirstChild("RemoteEvent"), f and f:FindFirstChild("RemoteFunction")
	end

	local MAP_WINS = { FARMHOUSE = 0, BASEMENT = 1, RANCH = 2, GRAVEYARD = 0 }
	local HARD_WINS = { FARMHOUSE = 1, BASEMENT = 2, RANCH = 3, GRAVEYARD = 1 }

	local function chosenRun()
		local map = CONFIG.map
		local w = wins()
		if (MAP_WINS[map] or 0) > w then map = "FARMHOUSE" end
		local diff = CONFIG.difficulty
		if diff == "HARD" and (HARD_WINS[map] or 1) > w then diff = "NORMAL" end
		return map, diff
	end

	-- GEM UPGRADES. The lobby shop asks the server through the ShopUI networker:
	-- fetch("BuyUpgrade", id). Cheapest next level first; a refusal means the
	-- gems are not there and the next try waits a minute.
	-- Everything the gems cover, cheapest level first, BEFORE the run starts:
	-- the first build bought one level and walked onto a pad, so 350 gems went
	-- into the next round as one upgrade. A purchase counts only when the level
	-- attribute moves - the shop's own return value is not trusted.
	local nextGemTry = 0
	local function gemUpgrades()
		if not CONFIG.gemUpgrades or os.clock() < nextGemTry then return end
		local _, fn = net("ShopUI")
		local ok, UC = pcall(function() return require(RS.Shared.Configs.UpgradeConfig) end)
		if not (fn and ok and type(UC) == "table" and type(UC.Upgrades) == "table") then return end
		local skip = {}
		for _ = 1, 30 do
			local best, bestPrice, key
			for _, u in ipairs(UC.Upgrades) do
				local k = "Upgrade" .. tostring(u.DataKey or u.Id)
				local lvl = tonumber(plr:GetAttribute(k)) or 0
				local price = u.Prices and u.Prices[lvl + 1]
				if price and not skip[u.Id] and (not bestPrice or price < bestPrice) then best, bestPrice, key = u, price, k end
			end
			if not best then break end
			local before = tonumber(plr:GetAttribute(key)) or 0
			pcall(function() fn:InvokeServer("BuyUpgrade", best.Id) end)
			local t0 = os.clock()
			while os.clock() - t0 < 1.5 and (tonumber(plr:GetAttribute(key)) or 0) <= before do task.wait(0.05) end
			if (tonumber(plr:GetAttribute(key)) or 0) > before then
				STATE.upgrades = STATE.upgrades + 1
				note("gem upgrade " .. tostring(best.Name or best.Id) .. " " .. (before + 1))
			else
				-- the cheapest is out of reach, so nothing dearer is in reach either
				break
			end
		end
		nextGemTry = os.clock() + 60
	end

	-- STARTING A RUN. Stand over an idle pad until the server answers with
	-- "Setup" (OpenSetup), then CreateParty(map, size, difficulty) - the exact
	-- call the game's own Create button makes. NEVER WITH bridge.py spy ARMED:
	-- the hook breaks this call in this game, the server then times the setup
	-- out with "You took too long to pick a map" and nothing else says why.
	local function startRun()
		local ev = net("PartyService")
		if not ev then note("no party service here") return false end
		local r = root()
		if not r then return false end
		local pad, best = nil, nil
		for _, m in ipairs(workspace:GetChildren()) do
			if m.Name == "Teleporter" and m:GetAttribute("PartyStatus") == "Idle" then
				local d = (m:GetPivot().Position - r.Position).Magnitude
				if not best or d < best then pad, best = m, d end
			end
		end
		if not pad then STATE.phase = "every pad is busy" return false end
		local p = pad:GetPivot().Position
		STATE.phase = "stepping onto a pad"
		local t0 = os.clock()
		while alive() and os.clock() - t0 < 8 and pad:GetAttribute("PartyStatus") ~= "Setup" do
			hold(CFrame.new(p + Vector3.new(0, 3, 0)), 0.1)
		end
		if pad:GetAttribute("PartyStatus") ~= "Setup" then note("pad never opened") return false end
		task.wait(0.8)
		local map, diff = chosenRun()
		STATE.phase = "creating " .. map .. " " .. diff
		pcall(function() ev:FireServer("CreateParty", map, 1, diff) end)
		local t1 = os.clock()
		while alive() and os.clock() - t1 < 4 do
			hold(CFrame.new(p + Vector3.new(0, 3, 0)), 0.1)
			if pad:GetAttribute("PartyStatus") == "Open" or pad:GetAttribute("PartyStatus") == "Cooldown" then break end
		end
		if pad:GetAttribute("PartyStatus") == "Open" or pad:GetAttribute("PartyStatus") == "Cooldown" then
			STATE.runs = STATE.runs + 1
			STATE.phase = "teleporting to " .. map
			-- stay on the pad through the countdown
			local t2 = os.clock()
			while alive() and os.clock() - t2 < 20 do hold(CFrame.new(p + Vector3.new(0, 3, 0)), 0.2) end
			return true
		end
		note("the party was not created")
		return false
	end

	function lobbyLoop()
		task.wait(3)
		while alive() do
			local ok, err = pcall(function()
				if not CONFIG.auto then STATE.phase = "idle (master switch off)" task.wait(0.5) return end
				gemUpgrades()
				if CONFIG.autoStart then
					startRun()
					task.wait(2)
				else
					STATE.phase = "waiting - auto start is off"
					task.wait(1)
				end
			end)
			if not ok then note("lobby: " .. tostring(err)) task.wait(2) end
		end
	end

	ENV.__NEEDLE_LOBBY = { startRun = startRun, gemUpgrades = gemUpgrades, chosenRun = chosenRun }
end

--------------------------------------------------------------------------------
-- staying in the game across places
--------------------------------------------------------------------------------
--
-- The hub follows this game across its own places by itself (it arms the queue
-- with this script's alias and the place list). Run by hand there is no hub, so
-- the queue is armed here instead - gated on the place ids, so it can never
-- start in a different game.
do
	local hubOwns = _G.__SEL and _G.__SEL.game and _G.__SEL.game.alias == "needle"
	if not hubOwns and not ENV.__NEEDLE_QUEUED then
		local q = queue_on_teleport or (syn and syn.queue_on_teleport)
		if q then
			ENV.__NEEDLE_QUEUED = true
			local ids = { LOBBY_PLACE }
			for id in pairs(MAP_PLACES) do ids[#ids + 1] = id end
			local list = {}
			for _, id in ipairs(ids) do list[#list + 1] = tostring(id) end
			pcall(q, "local ok = false for _, id in ipairs({" .. table.concat(list, ",") .. "}) do "
				.. "if game.PlaceId == id then ok = true end end if not ok then return end "
				.. "if isfile and isfile('needle.lua') then loadstring(readfile('needle.lua'))() end")
		end
	end
end

-- anti-AFK: the round is long and the lobby wait is longer
pcall(function()
	local VU = game:GetService("VirtualUser")
	plr.Idled:Connect(function()
		if not alive() or not CONFIG.antiAfk then return end
		pcall(function() VU:CaptureController() VU:ClickButton2(Vector2.new()) end)
	end)
end)

--------------------------------------------------------------------------------
-- panel
--------------------------------------------------------------------------------

local UI = (_G.__SEL and _G.__SEL.ui) or loadstring(readfile("ui-template.lua"))()
if ENV.__NEEDLE_WIN then pcall(function() ENV.__NEEDLE_WIN:Destroy() end) end
if UI.sweep then UI.sweep("SeluxNeedlePanel") end
UI.config("needle", CONFIG)

local win = UI.Window({
	name = "SeluxNeedlePanel", title = "SEARCH FOR THE", accentTitle = "NEEDLE", subtitle = "seltonmt",
})
ENV.__NEEDLE_WIN = win

local statusOut
do
	local page = win:Page("FARM", UI.icon and (UI.icon.pickaxe or UI.icon.target) or nil)
	local run = page:Card("IN THE MAP", 1):Accent()
	run:Toggle("Dig hay", CONFIG.farm, function(v) CONFIG.farm = v end,
		"picks strands with the game's own grab, as fast as the cooldown allows")
	run:Toggle("Dig the pile evenly", CONFIG.evenDig, function(v) CONFIG.evenDig = v end,
		"not needed: the needle shows once 75% of all the hay is gone, wherever it was dug")
	run:Toggle("Rare hay first", CONFIG.rareFirst, function(v) CONFIG.rareFirst = v end,
		"Gold, Void and the other mutations are worth up to 20x")
	run:Toggle("Sell at the cow", CONFIG.autoSell, function(v) CONFIG.autoSell = v end)
	run:Slider("Sell when the bag is (%)", 10, 100, CONFIG.sellAt, function(v) CONFIG.sellAt = v end)
	run:Toggle("Collect gems", CONFIG.gems, function(v) CONFIG.gems = v end)
	run:Toggle("Find and hand in the needle", CONFIG.needle, function(v) CONFIG.needle = v end,
		"digs the needle free once the game reveals it and takes it to the farmer")
	run:Dropdown("After a win", { "Auto", "Replay", "Lobby", "Stay" }, CONFIG.afterWin,
		function(v) CONFIG.afterWin = v end,
		"Auto goes to the lobby when there are gems to spend, and replays otherwise")

	local spend = page:Card("SPENDING", 2)
	spend:Toggle("Cash upgrades", CONFIG.cashUpgrades, function(v) CONFIG.cashUpgrades = v end,
		"speed, grab, bag - the cheapest next level first")
	spend:Toggle("Buy tools", CONFIG.buyTnt, function(v) CONFIG.buyTnt = v end,
		"the pitchfork first, then TNT, then the vacuum - and the drone with gems")
	spend:Toggle("Throw TNT", CONFIG.useTnt, function(v) CONFIG.useTnt = v end,
		"one blast took 278 strands, and all of them went into the bag past its cap")
	spend:Toggle("Pitchfork alongside the hand", CONFIG.useFork, function(v) CONFIG.useFork = v end,
		"the two cooldowns are separate, so both dig at once - about twice the rate")
	spend:Toggle("Use the vacuum", CONFIG.useVacuum, function(v) CONFIG.useVacuum = v end,
		"about 30 strands a second until it overheats, then the pitchfork takes over")
	spend:Toggle("Vacuum never overheats (pulse)", CONFIG.vacPulse, function(v) CONFIG.vacPulse = v end,
		"switched on for one frame per suck: same haul, a sixth of the heat - ~3 min to overheat instead of 30 s",
		UI.theme and UI.theme.warn)
	spend:Toggle("Gem upgrades in the lobby", CONFIG.gemUpgrades, function(v) CONFIG.gemUpgrades = v end)

	local lobby = page:Card("LOBBY", 2)
	lobby:Toggle("Start runs by itself", CONFIG.autoStart, function(v) CONFIG.autoStart = v end)
	lobby:Dropdown("Map", { "FARMHOUSE", "BASEMENT", "RANCH", "GRAVEYARD" }, CONFIG.map,
		function(v) CONFIG.map = v end, "a map you have not unlocked falls back to the Farmhouse")
	lobby:Dropdown("Difficulty", { "NORMAL", "HARD" }, CONFIG.difficulty,
		function(v) CONFIG.difficulty = v end)
	lobby:Toggle("Anti-AFK", CONFIG.antiAfk, function(v) CONFIG.antiAfk = v end)

	statusOut = page:Card("STATUS", 0):Readout(8)
end

win:Home()
pcall(function()
	win:SetMaster(CONFIG.auto, "Auto farm running")
	win:OnMaster(function(on) CONFIG.auto = on end)
end)

task.spawn(function()
	while alive() do
		pcall(function()
			local held = tonumber(attr("HayHeld", 0)) or 0
			local cap = tonumber(attr("HayCapacity", 25)) or 25
			statusOut:set({
				"place     " .. (IN_MAP and ("map " .. tostring(MAP_PLACES[game.PlaceId] or "?")) or "lobby"),
				"phase     " .. STATE.phase,
				string.format("bag       %d / %d   rate %.1f strands/s", held, cap, STATE.rate),
				string.format("cash      $%.2f   earned $%.2f   sells %d", cash(), STATE.earned, STATE.sells),
				string.format("picks     %d   fork %d   vacuum %d   moves %d   tnt %d   gems %d", STATE.picks, STATE.forks or 0, STATE.vacs or 0, STATE.moves, STATE.tnts, STATE.gems),
				"needle    " .. (attr("NeedleOwned", false) and "in hand" or (STATE.needleId and ("revealed, strand " .. STATE.needleId) or "not revealed yet")),
				string.format("wins      %d total   %d this session   runs %d", wins(), STATE.wins, STATE.runs),
				"note      " .. STATE.note,
			})
			win:SetStat(1, string.format("$%.2f", cash()), "cash")
			win:SetStat(2, tostring(wins()), "wins")
			win:SetStat(3, string.format("%d/%d", held, cap), "bag")
		end)
		task.wait(0.5)
	end
end)

ENV.__NEEDLE_DBG = { CONFIG = CONFIG, STATE = STATE, R = R, Config = Config, IN_MAP = IN_MAP }

if IN_MAP then task.spawn(mapLoop) else task.spawn(lobbyLoop) end
print("[selux needle] gen " .. GEN .. " ready (" .. (IN_MAP and "map" or "lobby") .. ") - RightShift for the panel")
