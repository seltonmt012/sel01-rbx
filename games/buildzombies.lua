--!nocheck
-- [Build and Kill Zombies] - build a car on the plot, drive it down the +X road
-- through the zombies, get paid per stud. Every lever below was measured live
-- against the server (bridge 1, 2026-09-30), nothing is assumed.
--
-- Oracle: Packets.GetData:Fire("Cash") returns the EXACT cash as a string
-- ("11339"); the leaderstat is abbreviated ("11.3K") and useless for deltas.
-- GetData("Distance") is the record. All packets are Suphi's Packet library in
-- RS.Packages.Packets - one RemoteEvent, typed arguments, no names on the wire.
--
-- What was verified:
--   * Run    SpawnCar:Fire() spawns the car at the plot and seats the driver.
--            Cash = ValidatedDistance x 4 / 10 plus zombie kills, and it is paid
--            LIVE during the run (+373 of +436 arrived before DespawnCar), so
--            ending a run early loses nothing. Fuel drains by TIME, not throttle
--            (15 -> 12.3 in 3s parked). At Fuel 0 the server stops counting.
--   * Fuel   Writing Fuel/FuelFrozen on the car (what the public "inf fuel"
--            scripts do) is client-only: ValidatedDistance froze at 433 while the
--            car kept rolling on the client. FuelTime = sum(Capacity)/sum(Drain),
--            so a Navy Barrel took one run from 15s to 135s - real, server side.
--   * Speed  The car is simulated on the client and the server validates it
--            (RunValidationConfig: strikes, 3 in 30s end the run). With a
--            TopSpeed-24 car on the open road 30, 60, 115, 120 were accepted
--            and paid in full; 160 / 200 / 250 got corrected back ("snap") and
--            the run ended. The allowance is tighter inside the zombie zones:
--            at ~2190 studs 115 was snapped and stalled at 2.1K, while 70, 90
--            and 105 all went through to the real zombie wall at 2.7K (+1.5K a
--            run instead of +1.1K). Default 100; adaptive mode drops 10 after a
--            run that snapped and fell short of 90% of the best distance.
--   * Drive  The game's own CarController drives from Humanoid.MoveDirection
--            when no key is held, and reads TopSpeed/Accel off the car's
--            attributes every step. So the script feeds Humanoid:Move() and
--            raises those two attributes locally: the game's own suspension,
--            ramps and steps do the driving, which a raw velocity write did not
--            (it stuck on the start ramp and on every step).
--   * Wall   Past ~2200 studs a starter car is stopped by zombies and killed
--            (snap + HP 97 -> 3). It is the game's real progression wall - the
--            zombies are server side (GunShot/ZombieCrushed/... are all
--            server -> client), so the only way past is a better car: weapons,
--            push bars, armour. That is what the roll/buy/build loop is for.
--   * Roll   Rolls/<Station>/Roll.ProximityPrompt, FREE, within ~5 studs, one
--            per ~2.5s (faster fires are ignored). The result is the LAST entry
--            of the RollSpin packet's list. SetRollCategories("Engine,Fuel")
--            filters the Blocks station (verified: only engines and tanks came).
--            ItemPlace.Attachment.BuyPrompt buys the shown part for its catalog
--            Cost (Navy Barrel 5250: cash 10.7K -> 5.48K, inventory +1). A rare
--            item on display blocks the next roll until RollConfirmation is
--            answered with ConfirmRollSkip(token, skip).
--   * Build  PlacePart(id, x, y, z, R, T) / RemovePart(x, y, z) on the plot grid;
--            parts are named "x,y,z" under Plot.Parts with PartId/R/T. Rules are
--            BuildUtils.CanPlace (26-neighbour touch above y=0, support slots
--            for weapons/turbo = 1 + BonusSupportSlots). Swapping SmallTank for
--            NavyBarrel at 7,1,6 was accepted.
--   * Skills BuySkill(id) costs cash (lucks_1: Luck 1 -> 1.1, cash -75). No
--            reliable owned-list read, so ownership is learned by trying.
--   * Codes  RedeemCode:Fire(code) answers {ok, summary}; CodesConfig lists them
--            with ExpiredTime / MinDistance.
--   * AFK    ClientSetupService.Misc.AfkRejoin asks the SERVER for a rejoin after
--            AfkConfig.IdleSeconds (900) without input - that rejoin hit this
--            session once. It reads the config table on every check, so setting
--            IdleSeconds to math.huge switches it off.

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")

local plr = Players.LocalPlayer

_G.__BUILDZOMBIES = (_G.__BUILDZOMBIES or 0) + 1
local generation = _G.__BUILDZOMBIES
if _G.__BUILDZOMBIES_GUI then pcall(function() _G.__BUILDZOMBIES_GUI:Destroy() end) end

-------------------------------------------------------------------- config -----

local CONFIG = {
	auto         = false,  -- master switch

	autoRun      = true,   -- spawn, drive, end, repeat
	speed        = 100,    -- studs/s; see the Speed note in the header
	adaptive     = true,   -- back off after an early correction, creep back up
	ghostObstacles = true, -- rocks/walls in front of the bumper lose collision (local)
	endOnStall   = true,   -- end the run once the distance stops growing
	stallSeconds = 3,

	autoRoll     = true,
	rollBlocks   = true,   -- Blocks station: blocks, engines, fuel, wheels
	rollWeapons  = true,   -- Weapons station: guns, push bars, launchers
	rollsPerCycle = 6,     -- rolls per station between two runs
	catBlock     = true,
	catEngine    = true,
	catFuel      = true,
	catWheel     = true,

	autoBuy      = true,   -- buy a rolled part when it improves the car
	holdRare     = true,   -- keep an unaffordable upgrade on display and farm for it
	holdRuns     = 10,     -- ...if it costs at most this many runs of cash

	autoBuild    = true,   -- swap better parts into the car, same cell
	addWeapons   = true,   -- fill free weapon slots with the best owned weapon

	autoSkills   = true,
	skillShare   = 0.6,    -- a skill may cost at most this share of the cash

	autoCodes    = true,
	autoQuests   = true,
	antiAfk      = true,
}

local STATE = {
	cash = 0, record = 0, plot = "-",
	runs = 0, runCash = 0, lastDist = 0, bestDist = 0, lastRunCash = 0,
	runStart = 0, cashStart = nil, sessionStart = os.clock(),
	snaps = 0, speedAdj = 0, cleanRuns = 0,
	rolls = 0, bought = 0, swaps = 0, weaponsAdded = 0, skills = 0, codes = 0,
	hold = {},             -- station -> {id, cost}
	lastRoll = {},         -- station -> id
	topSpeed = 0, fuelTime = 0, support = "-", carParts = 0,
	phase = "idle", note = "-",
}

-------------------------------------------------------------- game handles -----

local Packets      = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Packets"))
local Data         = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Data")
local PartCatalog  = require(Data:WaitForChild("PartCatalog"))
local BuildUtils   = require(ReplicatedStorage.Shared:WaitForChild("Utils"):WaitForChild("BuildUtils"))
local SkillConfig  = require(Data:WaitForChild("SkillConfig"))
local CodesConfig  = require(Data:WaitForChild("CodesConfig"))
local QuestConfig  = require(Data:WaitForChild("QuestConfig"))

local STATIONS = { Blocks = "RollBlocks", Weapons = "RollWeapons" }

local function alive() return _G.__BUILDZOMBIES == generation end

-- Packet callbacks run on the game's side and see a DIFFERENT _G: inside one,
-- _G.__BUILDZOMBIES read nil while the script's own thread read 1, so alive()
-- was false there and the inventory table never filled. Callbacks read this
-- upvalue instead, kept current from the script's own thread.
local live = true
task.spawn(function()
	while live do
		live = alive()
		task.wait(0.5)
	end
end)

local function fmt(n)
	n = tonumber(n) or 0
	local a = math.abs(n)
	if a >= 1e12 then return string.format("%.2fT", n / 1e12) end
	if a >= 1e9 then return string.format("%.2fB", n / 1e9) end
	if a >= 1e6 then return string.format("%.2fM", n / 1e6) end
	if a >= 1e3 then return string.format("%.1fK", n / 1e3) end
	return tostring(math.floor(n + 0.5))
end

local function note(text) STATE.note = text end

-- Exact cash off the server. Falls back to the last good read; the leaderstat is
-- an abbreviated string and is only a last resort.
local function readCash()
	local ok, r = pcall(function() return Packets.GetData:Fire("Cash") end)
	local n = ok and tonumber(r)
	if n then STATE.cash = n return n end
	local ls = plr:FindFirstChild("leaderstats")
	local v = ls and ls:FindFirstChild("💵 Cash")
	if v then
		local s = tostring(v.Value)
		local num, suf = s:match("([%d%.]+)(%a?)")
		local mult = ({ K = 1e3, M = 1e6, B = 1e9, T = 1e12 })[suf or ""] or 1
		if num then STATE.cash = tonumber(num) * mult end
	end
	return STATE.cash
end

local function readRecord()
	local ok, r = pcall(function() return Packets.GetData:Fire("Distance") end)
	local n = ok and tonumber(r)
	if n then STATE.record = n end
	return STATE.record
end

local function humanoid()
	local c = plr.Character
	return c and c:FindFirstChildOfClass("Humanoid")
end

local function myPlot()
	local plots = workspace:FindFirstChild("Game") and workspace.Game:FindFirstChild("Lobby")
		and workspace.Game.Lobby:FindFirstChild("Plots")
	if not plots then return nil end
	for _, p in ipairs(plots:GetChildren()) do
		if p:GetAttribute("OwnerUserId") == plr.UserId then return p end
	end
end

local function myCar()
	local cars = workspace:FindFirstChild("Cars")
	if not cars then return nil end
	for _, m in ipairs(cars:GetChildren()) do
		if m:GetAttribute("OwnerUserId") == plr.UserId then return m end
	end
end

------------------------------------------------------------------ inventory -----

-- InventoryChanged carries the absolute count per part id; RequestInventory makes
-- the server send every id once.
local INV = {}
local invConn = Packets.InventoryChanged.OnClientEvent:Connect(function(id, n)
	if not live then return end
	INV[id] = n
end)
pcall(function() Packets.RequestInventory:Fire() end)

----------------------------------------------------------------- part scores -----

local SCORE_STAT = {
	Engine = "TopSpeed", Fuel = "Capacity", Wheel = "Support", PushBar = "Damage",
	Gun = "DPS", Explosion = "DPS", Laser = "DPS", Beam = "DPS", Poison = "DPS",
	Turbo = "SpeedMult",
}
-- Groups a part competes in. Weapons share the support slots, so they compete
-- with each other on DPS. Turbos also take a slot but need the nitro mechanic,
-- so they are only ever upgraded in place, never added.
local WEAPON_CATS = { Gun = true, Explosion = true, Laser = true, Beam = true, Poison = true, Boost = true }
local SWAPPABLE = { Engine = true, Fuel = true, Wheel = true, PushBar = true, Block = true,
	Weapon = true, Turbo = true }

local function def(id) return PartCatalog.Parts[id] end

local function group(id)
	local d = def(id)
	if not d then return nil end
	if WEAPON_CATS[d.Category] then return "Weapon" end
	return d.Category
end

local function score(id)
	local d = def(id)
	if not d then return 0 end
	local base
	if d.Category == "Block" then
		base = d.HP or 0
	else
		local st = SCORE_STAT[d.Category]
		base = (st and d.Stats and d.Stats[st]) or 0
	end
	return base + (d.HP or 0) * 1e-4
end

local function displayName(id)
	local d = def(id)
	local ok, name = pcall(function() return PartCatalog.DisplayName(id) end)
	return (ok and type(name) == "string" and name) or (d and d.Name) or id
end

--------------------------------------------------------------------- build -----

local function readBuild()
	local plot = myPlot()
	local grid = {}
	if not plot or not plot:FindFirstChild("Parts") then return grid, plot end
	for _, m in ipairs(plot.Parts:GetChildren()) do
		local id = m:GetAttribute("PartId")
		if id then grid[m.Name] = { Id = id, R = m:GetAttribute("R") or 0, T = m:GetAttribute("T") or 0 } end
	end
	return grid, plot
end

local function supportBudget()
	local ok, n = pcall(function()
		return math.min(BuildUtils.GetSupportBudget(BuildUtils.BonusSlotsOf(plr)), BuildUtils.MAX_SUPPORT_PARTS)
	end)
	return ok and n or 1
end

local function aggregates(grid)
	local ok, agg = pcall(BuildUtils.ComputeAggregates, grid)
	return ok and agg or nil
end

-- Weakest placed score per group, plus how many of the group are placed.
local function placedByGroup(grid)
	local out = {}
	for key, cell in pairs(grid) do
		local g = group(cell.Id)
		if g then
			local s = score(cell.Id)
			local e = out[g]
			if not e then e = { min = s, n = 0, cells = {} } out[g] = e end
			if s < e.min then e.min = s end
			e.n = e.n + 1
			table.insert(e.cells, key)
		end
	end
	return out
end

-- Best part of a group sitting unused in the inventory.
local function bestSpare(g, above)
	local best, bestScore = nil, above or -math.huge
	for id, n in pairs(INV) do
		if (n or 0) > 0 and group(id) == g then
			local s = score(id)
			if s > bestScore then best, bestScore = id, s end
		end
	end
	return best, bestScore
end

local function partAt(plot, key)
	local m = plot and plot:FindFirstChild("Parts") and plot.Parts:FindFirstChild(key)
	return m and m:GetAttribute("PartId")
end

local function ensureOnFoot()
	local car = myCar()
	local hum = humanoid()
	if car or (hum and hum.SeatPart) then
		pcall(function() Packets.DespawnCar:Fire() end)
		for _ = 1, 20 do
			task.wait(0.2)
			local h = humanoid()
			if not myCar() and not (h and h.SeatPart) then break end
		end
		task.wait(0.5)
	end
end

-- Swap the best spare part into the weakest cell of its group, one cell at a
-- time. The removed part goes back to the inventory, so the loop converges.
local function upgradeInPlace()
	local did = 0
	for _ = 1, 30 do
		if not alive() then break end
		local grid, plot = readBuild()
		if not plot then break end
		local target, targetId
		local bestGain = 0
		for key, cell in pairs(grid) do
			local g = group(cell.Id)
			if g and SWAPPABLE[g] then
				local cur = score(cell.Id)
				local spare, s = bestSpare(g, cur)
				if spare and s - cur > bestGain then
					bestGain = s - cur
					target, targetId = key, spare
				end
			end
		end
		if not target then break end
		local cell = grid[target]
		local x, y, z = BuildUtils.ParseKey(target)
		ensureOnFoot()
		Packets.RemovePart:Fire(x, y, z)
		task.wait(0.45)
		Packets.PlacePart:Fire(targetId, x, y, z, cell.R or 0, cell.T or 0)
		task.wait(0.8)
		if partAt(plot, target) == targetId then
			did = did + 1
			STATE.swaps = STATE.swaps + 1
			note(string.format("swapped %s -> %s", displayName(cell.Id), displayName(targetId)))
		else
			-- Put the original back so a rejected swap never leaves a hole.
			if not partAt(plot, target) then
				Packets.PlacePart:Fire(cell.Id, x, y, z, cell.R or 0, cell.T or 0)
				task.wait(0.6)
			end
			note("swap refused: " .. displayName(targetId))
			break
		end
	end
	return did
end

local NEIGH = {}
for dx = -1, 1 do for dy = -1, 1 do for dz = -1, 1 do
	if not (dx == 0 and dy == 0 and dz == 0) then table.insert(NEIGH, Vector3.new(dx, dy, dz)) end
end end end

-- A free cell for a new weapon: touching the car, above the ground, preferring a
-- cell that sits ON a part and is high up. CanPlace is the game's own rule.
local function freeCellFor(grid, plot, id)
	local dims = plot:GetAttribute("GridDims")
	local bonus = BuildUtils.BonusSlotsOf(plr)
	local more = plr:GetAttribute("TotalMorePlacement")
	local okSet, connected = pcall(BuildUtils.GetConnectedSet, grid)
	if not okSet then connected = grid end
	local best, bestScore
	for key in pairs(connected) do
		local x, y, z = BuildUtils.ParseKey(key)
		for _, o in ipairs(NEIGH) do
			local cx, cy, cz = x + o.X, y + o.Y, z + o.Z
			if cy >= 1 then
				local ck = BuildUtils.Key(cx, cy, cz)
				if not grid[ck] then
					local ok, can = pcall(BuildUtils.CanPlace, grid, id, cx, cy, cz, dims, bonus, false, more)
					if ok and can then
						local s = cy * 2 + (grid[BuildUtils.Key(cx, cy - 1, cz)] and 10 or 0)
						if not bestScore or s > bestScore then best, bestScore = { cx, cy, cz }, s end
					end
				end
			end
		end
	end
	return best
end

local function addWeapons()
	local did = 0
	for _ = 1, 12 do
		if not alive() then break end
		local grid, plot = readBuild()
		if not plot then break end
		local used = BuildUtils.CountSupportParts(grid)
		if used >= supportBudget() then break end
		local id = bestSpare("Weapon")
		if not id then break end
		local cell = freeCellFor(grid, plot, id)
		if not cell then note("no free cell for " .. displayName(id)) break end
		ensureOnFoot()
		Packets.PlacePart:Fire(id, cell[1], cell[2], cell[3], 0, 0)
		task.wait(0.8)
		if partAt(plot, BuildUtils.Key(cell[1], cell[2], cell[3])) == id then
			did = did + 1
			STATE.weaponsAdded = STATE.weaponsAdded + 1
			note("mounted " .. displayName(id))
		else
			note("mount refused: " .. displayName(id))
			break
		end
	end
	return did
end

local function refreshCarStats()
	local grid = readBuild()
	local agg = aggregates(grid)
	if agg then
		STATE.topSpeed = agg.TopSpeed or 0
		STATE.fuelTime = agg.FuelTime or 0
		STATE.carParts = agg.PartCount or 0
	end
	STATE.support = string.format("%d / %d", BuildUtils.CountSupportParts(grid), supportBudget())
end

local function doBuild()
	STATE.phase = "building"
	local n = 0
	if CONFIG.autoBuild then n = n + upgradeInPlace() end
	if CONFIG.addWeapons then n = n + addWeapons() end
	refreshCarStats()
	return n
end

---------------------------------------------------------------------- roll -----

-- Is this rolled part worth buying for the car as it stands?
local function wanted(id)
	local d = def(id)
	if not d then return false end
	local g = group(id)
	if not g or not SWAPPABLE[g] then return false end
	local grid = readBuild()
	local placed = placedByGroup(grid)
	local s = score(id)
	-- An unused spare already as good as this one makes it pointless.
	local spare, spareScore = bestSpare(g)
	if g == "Weapon" then
		local used = BuildUtils.CountSupportParts(grid)
		if used < supportBudget() and not spare then return true, "free weapon slot" end
		local e = placed.Weapon
		if e and s > e.min and not (spare and spareScore >= s) then return true, "stronger weapon" end
		return false
	end
	local e = placed[g]
	if not e then return false end
	if s > e.min and not (spare and spareScore >= s) then return true, "upgrade " .. g end
	return false
end

local function categoriesString()
	local cats = {}
	if CONFIG.catBlock then table.insert(cats, "Block") end
	if CONFIG.catEngine then table.insert(cats, "Engine") end
	if CONFIG.catFuel then table.insert(cats, "Fuel") end
	if CONFIG.catWheel then table.insert(cats, "Wheel") end
	if #cats == 0 then cats = { "Engine", "Fuel" } end
	return table.concat(cats, ",")
end

local function applyCategories()
	local want = categoriesString()
	if plr:GetAttribute("RollCategories") ~= want then
		pcall(function() Packets.SetRollCategories:Fire(want) end)
	end
end

local function walkTo(pos, radius, timeout)
	local hum = humanoid()
	local root = plr.Character and plr.Character:FindFirstChild("HumanoidRootPart")
	if not hum or not root then return false end
	local t0 = os.clock()
	local lastIssue = 0
	while alive() and os.clock() - t0 < (timeout or 10) do
		if (root.Position - pos).Magnitude <= (radius or 4) then return true end
		if os.clock() - lastIssue > 1.5 then
			hum:MoveTo(pos)
			lastIssue = os.clock()
		end
		task.wait(0.15)
	end
	return (root.Position - pos).Magnitude <= (radius or 4)
end

local function stationFolder(station)
	local plot = myPlot()
	return plot and plot:FindFirstChild("Rolls") and plot.Rolls:FindFirstChild(station)
end

local function norm(s)
	s = tostring(s or ""):gsub("<[^>]->", ""):gsub("^x%d+%s*", "")
	return (s:lower():gsub("[^%a%d]", ""))
end

local function editDistance(a, b)
	if math.abs(#a - #b) > 3 then return 99 end
	local prev = {}
	for j = 0, #b do prev[j] = j end
	for i = 1, #a do
		local cur = { [0] = i }
		for j = 1, #b do
			local cost = (a:sub(i, i) == b:sub(j, j)) and 0 or 1
			cur[j] = math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
		end
		prev = cur
	end
	return prev[#b]
end

-- The label is not the catalog name verbatim: blocks read "x5 Carbon Fiber
-- Slab", and Double Barrels is displayed as "Double arrels". Compare loosely.
local function showing(st, id)
	local lbl = st:FindFirstChild("Info") and st.Info:FindFirstChild("ItemName")
	if not lbl or lbl.Text == "???" then return false end
	local a, b = norm(lbl.Text), norm(displayName(id))
	return a == b or a:find(b, 1, true) ~= nil or b:find(a, 1, true) ~= nil or editDistance(a, b) <= 2
end

local function buyShown(st, id)
	local prompt = st:FindFirstChild("ItemPlace") and st.ItemPlace:FindFirstChild("Attachment")
		and st.ItemPlace.Attachment:FindFirstChild("BuyPrompt")
	if not prompt then return false end
	-- The prompt reaches 5 studs; the pedestal itself cannot be walked closer than
	-- ~4.4, so a 4.3 radius burned the whole walk timeout on every purchase.
	local itemPos = st.ItemPlace:IsA("BasePart") and st.ItemPlace.Position or st.ItemPlace:GetPivot().Position
	walkTo(itemPos, 4.8, 6)
	-- The prompt only switches on once the 2.5s spin animation has finished and
	-- the part is on display. Firing earlier hits a disabled prompt and does
	-- nothing - that is how an Engine V2 "purchase" bought nothing at all.
	local t0 = os.clock()
	while os.clock() - t0 < 6 and not (prompt.Enabled and showing(st, id)) do task.wait(0.1) end
	if not (prompt.Enabled and showing(st, id)) then return false end
	local d = def(id)
	local cost = d and d.Cost or 0
	local before = INV[id] or 0
	local cashBefore = readCash()
	fireproximityprompt(prompt)
	-- InventoryChanged can arrive several seconds late (a Mounted Gun landed after
	-- a 2.5s window had closed), so a cash drop counts too - but only one that
	-- matches this part's price, or a late earlier purchase gets credited to it.
	local ok = false
	for i = 1, 35 do
		task.wait(0.2)
		if (INV[id] or 0) > before then ok = true break end
		if i % 5 == 0 and cost > 0 then
			local drop = cashBefore - readCash()
			if drop >= cost * 0.75 and drop <= cost * 1.25 then ok = true break end
		end
	end
	if ok then
		STATE.bought = STATE.bought + 1
		note(string.format("bought %s for %s", displayName(id), fmt(cashBefore - readCash())))
	end
	return ok
end

-- The game asks "skip this Legendary item?" before a roll replaces a rare part,
-- and an answer sent at once jammed the station: every later roll was ignored
-- with no packet back (the dialog runs a 3s RollCooldown first). The question
-- is a plain player setting (SettingsConfig: RollConfirmation, "Off" is valid),
-- so it is switched off and holding is done by leaving the station alone.
local function applySettings()
	pcall(function()
		local s = Packets.LoadSettings:Fire()
		if type(s) ~= "table" then s = {} end
		if s.RollConfirmation ~= "Off" then
			s.RollConfirmation = "Off"
			Packets.SaveSettings:Fire(s)
		end
	end)
end
task.spawn(applySettings)

-- Fallback if the setting ever comes back: answer only after the cooldown.
local confirmConn = Packets.RollConfirmation.OnClientEvent:Connect(function(_, station, id, token)
	if not live then return end
	local hold = STATE.hold[station]
	local keep = hold and hold.id == id
	task.delay(3.5, function()
		pcall(function() Packets.ConfirmRollSkip:Fire(token, not keep) end)
	end)
end)

local function rollStation(station, manual)
	local st = stationFolder(station)
	if not st or not st:FindFirstChild("Roll") then return end

	-- A held upgrade blocks the station until it is affordable or gone.
	local hold = STATE.hold[station]
	if hold then
		if not showing(st, hold.id) then
			STATE.hold[station] = nil
		elseif readCash() >= hold.cost then
			ensureOnFoot()
			if buyShown(st, hold.id) then STATE.hold[station] = nil end
			return
		else
			return
		end
	end

	ensureOnFoot()
	if station == STATIONS.Blocks then applyCategories() end
	if not walkTo(st.Roll.Position, 4, 10) then note("could not reach " .. station) return end

	local result
	local conn = Packets.RollSpin.OnClientEvent:Connect(function(_, stName, list)
		if stName == station and type(list) == "table" then result = list[#list] end
	end)
	local misses = 0
	for _ = 1, math.max(1, CONFIG.rollsPerCycle) do
		if not (alive() and (manual or (CONFIG.auto and CONFIG.autoRoll))) then break end
		result = nil
		local t0 = os.clock()
		fireproximityprompt(st.Roll.ProximityPrompt)
		repeat task.wait(0.05) until result or os.clock() - t0 > 4
		if not result then
			misses = misses + 1
			if misses >= 2 then note(station .. " is not answering, skipped") break end
		else
			misses = 0
		end
		if result then
			STATE.rolls = STATE.rolls + 1
			STATE.lastRoll[station] = result
			local want, why = wanted(result)
			if want and CONFIG.autoBuy then
				local d = def(result)
				local cost = d and d.Cost or math.huge
				task.wait(0.4) -- let the display settle before walking to it
				if readCash() >= cost then
					buyShown(st, result)
					walkTo(st.Roll.Position, 4, 8)
				elseif CONFIG.holdRare and cost <= STATE.cash + math.max(STATE.lastRunCash, 100) * CONFIG.holdRuns then
					STATE.hold[station] = { id = result, cost = cost }
					note(string.format("holding %s (%s) - %s", displayName(result), fmt(cost), why or ""))
					break
				end
			end
		end
		task.wait(2.6)
	end
	conn:Disconnect()
end

local function doRolls(manual)
	STATE.phase = "rolling"
	if CONFIG.rollBlocks then rollStation(STATIONS.Blocks, manual) end
	if CONFIG.rollWeapons then rollStation(STATIONS.Weapons, manual) end
end

---------------------------------------------------------------------- run -----

local function targetSpeed(serverTop)
	local s = math.max(40, CONFIG.speed + (CONFIG.adaptive and STATE.speedAdj or 0))
	-- A car that is legitimately faster than the slider keeps its own speed.
	return math.max(s, serverTop or 0)
end

local BIND = "SeluxBKZ" .. generation

-- Obstacles. Every good run used to end at exactly 2676 studs: a rock pile
-- ~16 studs tall stands on the road there and the car wedged itself into it.
-- Steering around such piles (lane planning over raycasts) was tried and made
-- runs SHORTER - the lane changes drove into zombie packs and terrace edges. So
-- the car keeps its own straight line and whatever a box sweep finds in front
-- of the bumper, above ground level, has its collision switched off locally.
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.RespectCanCollide = true -- already-ghosted parts drop out by themselves

local function refreshRayFilter()
	local list = {}
	for _, name in ipairs({ "Cars", "ClientZombies", "ClientBosses", "ClientEffects", "Vfx" }) do
		local f = workspace:FindFirstChild(name)
		if f then table.insert(list, f) end
	end
	if plr.Character then table.insert(list, plr.Character) end
	rayParams.FilterDescendantsInstances = list
end

-- The sweep: a car-wide box starting 4 studs above the ground under the car,
-- pushed 45 studs forward. The ground and anything the wheels roll over stay
-- solid; every part it touches is made non-collidable (locally - nobody else
-- sees it) and remembered so it can be restored when the run ends.
local ghosted = {}

-- World-space extents of a (possibly rotated) part.
local function extents(part)
	local cf, s = part.CFrame, part.Size
	local function ext(v)
		return math.abs(cf.RightVector:Dot(v)) * s.X / 2 + math.abs(cf.UpVector:Dot(v)) * s.Y / 2
			+ math.abs(cf.LookVector:Dot(v)) * s.Z / 2
	end
	return ext(Vector3.xAxis), ext(Vector3.yAxis), ext(Vector3.zAxis)
end

-- What loses its collision: everything in the stage geometry that is THICK
-- (4+ studs tall) and narrow in at least one direction. What stays solid: the
-- stage floor slabs (thin - 375 x 2 x 948 at y 91 in Stage_2), thin ramp
-- plates, and road segments large both ways (a 84 -> 94 step at ~1000 studs;
-- ghosting that one dropped the car through the world to y -346).
-- Measured on the way here: a sweep that ghosted only what was in front of the
-- bumper got past the rock pile at 2677 but then wedged itself half-inside the
-- road hump at 2333, because some hump blocks were ghosted and their neighbours
-- were not. Doing the whole stage the same way is what makes it consistent.
-- Floor is thin, or large in BOTH horizontal directions. The road hump at
-- ~2360 is a wall 363 long but only 11 thick and 10 tall across the whole road;
-- a "large = floor" rule kept it solid while its neighbours were ghosted, and
-- the car wedged against it. A long, narrow, thick part is a wall.
-- Small pieces go too, however thin: the hump's staircase is 10x1x11 plates
-- at 95..102 that sat on the thick blocks, and once those were ghosted the
-- plates hung in the air at bumper height and stopped the car at 2330.
-- Thickness is the part's OWN smallest dimension, not its world height: the
-- start ramp is 6x1x393 planks tilted downhill, whose world height reads as
-- "thick" - ghosting them holed the ramp and the car stuck at 92 studs.
local function isObstacle(part)
	local hx, _, hz = extents(part)
	local s = part.Size
	if math.max(hx, hz) * 2 < 60 then return true end        -- small piece
	if math.min(s.X, s.Y, s.Z) < 4 then return false end     -- long plank / slab
	if math.min(hx, hz) * 2 > 60 then return false end       -- big both ways
	return true                                              -- thick, narrow: wall
end

-- ...and only if it stands more than 3 studs above the ground the car is on.
-- The Mine entrance floor is a 79x10x49 block whose TOP is the road; by shape
-- alone it read as a wall, was ghosted, and the car fell into the pit under it
-- (y 31 at 3020 studs). Anything level with the road stays solid.
local stagesFolder = nil
local function ghostAround(pp, axis, groundY)
	if not CONFIG.ghostObstacles then return end
	stagesFolder = stagesFolder or (workspace:FindFirstChild("Game") and workspace.Game:FindFirstChild("Stages"))
	if not stagesFolder then return end
	local center = pp.Position + axis * 120 + Vector3.new(0, 20, 0)
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { stagesFolder }
	params.RespectCanCollide = true
	local box = CFrame.lookAt(center, center + axis)
	for _, p in ipairs(workspace:GetPartBoundsInBox(box, Vector3.new(400, 80, 270), params)) do
		if p.CanCollide and isObstacle(p) then
			local _, hy = extents(p)
			if p.Position.Y + hy > groundY + 3 then
				p.CanCollide = false
				ghosted[p] = true
				STATE.ghosted = (STATE.ghosted or 0) + 1
			end
		end
	end
end

local function applyGhosts() end -- kept for the panel toggle; the run loop does the work
local ghostConn

local function restoreGhosts()
	if ghostConn then ghostConn:Disconnect() ghostConn = nil end
	for part in pairs(ghosted) do
		pcall(function() part.CanCollide = true end)
	end
	table.clear(ghosted)
end

local function doRun(manual)
	STATE.phase = "driving"
	ensureOnFoot()
	local cash0 = readCash()
	pcall(function() Packets.SpawnCar:Fire() end)
	local car
	for _ = 1, 60 do
		task.wait(0.1)
		car = myCar()
		if car and car.PrimaryPart then break end
	end
	if not (car and car.PrimaryPart) then note("car did not spawn") return end

	local pp = car.PrimaryPart
	local origin = car:GetAttribute("RunOrigin") or pp.Position
	local axis = car:GetAttribute("RunAxis") or Vector3.new(1, 0, 0)
	axis = Vector3.new(axis.X, 0, axis.Z)
	axis = axis.Magnitude > 0 and axis.Unit or Vector3.new(1, 0, 0)
	local side = Vector3.new(-axis.Z, 0, axis.X)
	local serverTop = car:GetAttribute("TopSpeed") or 0
	local spd = targetSpeed(serverTop)
	local accel = math.max(car:GetAttribute("Accel") or 0, 40)
	local snaps, lastP = 0, nil
	local bestBefore = STATE.bestDist
	local targetLat = 0
	local driving = true
	local lastGround = pp.Position.Y

	refreshRayFilter()
	task.spawn(function()
		while driving and pp.Parent do
			pcall(function()
				local down = workspace:Raycast(pp.Position + Vector3.new(0, 2, 0), Vector3.new(0, -20, 0), rayParams)
				if down then
					lastGround = down.Position.Y
					ghostAround(pp, axis, down.Position.Y)
				end
			end)
			task.wait(0.3)
		end
	end)

	RunService:BindToRenderStep(BIND, Enum.RenderPriority.Last.Value, function()
		if not pp.Parent then return end
		if car:GetAttribute("TopSpeed") ~= spd then car:SetAttribute("TopSpeed", spd) end
		if (car:GetAttribute("Accel") or 0) < accel then car:SetAttribute("Accel", accel) end
		local hum = humanoid()
		if not hum then return end
		local rel = pp.Position - origin
		local along = rel:Dot(axis)
		local err = targetLat - rel:Dot(side)
		local k = math.clamp(err * 0.02, -0.5, 0.5)
		hum:Move((axis + side * k).Unit, false)
		if lastP and along < lastP - 5 then snaps = snaps + 1 end
		lastP = along
	end)

	local t0 = os.clock()
	local lastVd, lastGrow = 0, os.clock()
	while alive() and car.Parent and (manual or (CONFIG.auto and CONFIG.autoRun)) do
		task.wait(0.25)
		local vd = car:GetAttribute("ValidatedDistance") or 0
		if vd > lastVd + 1 then lastVd, lastGrow = vd, os.clock() end
		STATE.lastDist = vd
		if (car:GetAttribute("Fuel") or 1) <= 0 then task.wait(1) break end
		-- Fell through a floor that was ghosted by mistake: stop ghosting for the
		-- session rather than losing every run the same way.
		if pp.Position.Y < lastGround - 40 then
			CONFIG.ghostObstacles = false
			restoreGhosts()
			note("fell through the track - obstacle ghosting switched off")
			break
		end
		if CONFIG.endOnStall and os.clock() - t0 > 5 and os.clock() - lastGrow > CONFIG.stallSeconds then break end
		if os.clock() - t0 > 400 then break end
	end
	driving = false
	RunService:UnbindFromRenderStep(BIND)
	local dist = car:GetAttribute("ValidatedDistance") or lastVd
	pcall(function() Packets.DespawnCar:Fire() end)
	task.wait(1.5)

	local gained = readCash() - cash0
	STATE.runs = STATE.runs + 1
	STATE.lastDist = dist
	STATE.lastRunCash = math.max(gained, 0)
	STATE.runCash = STATE.runCash + math.max(gained, 0)
	if dist > STATE.bestDist then STATE.bestDist = dist end
	STATE.snaps = snaps

	-- Adaptive speed: corrections plus a run that fell well short of the best one
	-- means the zone allowance was exceeded (115 snapped at 2.1K where 105 reached
	-- the real wall at 2.7K); clean runs earn the speed back.
	if CONFIG.adaptive then
		if snaps > 0 and bestBefore > 0 and dist < bestBefore * 0.9 then
			STATE.speedAdj = math.max(STATE.speedAdj - 10, 60 - CONFIG.speed)
			STATE.cleanRuns = 0
		else
			STATE.cleanRuns = STATE.cleanRuns + 1
			if STATE.cleanRuns >= 3 and STATE.speedAdj < 0 then
				STATE.speedAdj = math.min(0, STATE.speedAdj + 5)
				STATE.cleanRuns = 0
			end
		end
	end
	note(string.format("run %d: %s studs, +%s cash at %s studs/s", STATE.runs, fmt(dist), fmt(gained), fmt(spd)))
end

------------------------------------------------------------------- skills -----

-- Permanent upgrades, most useful first: weapon slots, damage, car health, luck,
-- golden/rainbow rolls, then placement. Paint and plot expansion are left out.
local SKILL_ORDER = {
	"moreweapon_1", "lucks_1", "lucks_2", "moreweapon_2", "lucks_3", "lucks_4",
	"weapondamage_1", "moreweapon_3", "goldenroll_1", "lucks_5", "lucks_6",
	"goldenroll_2", "moreweapon_4", "goldenroll_3", "plot_portal", "moreplacement_1",
	"moreluck_portal", "lucks_7", "goldenroll_4", "goldenroll_5", "rainbowroll_1",
	"rainbowroll_2", "rainbowroll_3", "lucks_8", "rainbowroll_4", "lucks_9",
	"moreplacement_2", "goldenroll_6", "weapondamage_2", "lucks_10", "rainbowroll_5",
	"moreweapon_5", "lucks_11", "goldenroll_7", "lucks_12", "carhealth_1",
	"rainbowroll_6", "lucks_13", "lucks_14", "weapondamage_3", "moreweapon_6",
	"moreplacement_3", "carhealth_2", "moreweapon_7", "weapondamage_4", "carhealth_3",
	"moreplacement_4", "weapondamage_5", "moreplacement_5", "weapondamage_6",
}
local skillOwned = { start = true, moreluck_root = true, plotskill_root = true }
local skillTried = {}

local function skillNode(id)
	return SkillConfig.ById and SkillConfig.ById[id]
end

local function doSkills()
	for _, id in ipairs(SKILL_ORDER) do
		if not alive() then return end
		local node = skillNode(id)
		if node and not skillOwned[id] then
			local parent = node.Parent
			local rootOk = parent == nil or skillOwned[parent]
			local cost = node.Cost or 0
			if rootOk then
				local cash = readCash()
				if cost <= 0 or cost <= cash * CONFIG.skillShare then
					pcall(function() Packets.BuySkill:Fire(id) end)
					task.wait(1.2)
					local after = readCash()
					skillOwned[id] = true -- bought now, or already owned before
					if cost > 0 and cash - after >= cost * 0.9 then
						STATE.skills = STATE.skills + 1
						note("skill " .. id .. " for " .. fmt(cost))
					end
				else
					return -- next one in priority is not affordable yet; save for it
				end
			end
		end
	end
end

------------------------------------------------------------- codes, quests -----

local codeDone = {}
local function doCodes()
	local now = os.time()
	local record = readRecord()
	for code, cfg in pairs(CodesConfig) do
		if type(cfg) == "table" and cfg.Active and not codeDone[code]
			and (not cfg.ExpiredTime or cfg.ExpiredTime > now)
			and (not cfg.MinDistance or record >= cfg.MinDistance) then
			codeDone[code] = true
			local ok, r = pcall(function() return Packets.RedeemCode:Fire(code) end)
			if ok and type(r) == "table" and r.ok then
				STATE.codes = STATE.codes + 1
				note("code " .. code .. ": " .. tostring(r.summary))
			end
			task.wait(0.5)
		end
	end
end

local function doQuests()
	for _, q in ipairs(QuestConfig.Quests or {}) do
		pcall(function() Packets.ClaimQuest:Fire(q.Id) end)
		task.wait(0.2)
	end
	pcall(function() Packets.ClaimOffline:Fire() end)
end

------------------------------------------------------------------ anti afk -----

local function applyAntiAfk()
	pcall(function()
		local cfg = require(Data:WaitForChild("AfkConfig"))
		cfg.IdleSeconds = CONFIG.antiAfk and math.huge or 900
	end)
end
applyAntiAfk()

local idleConn = plr.Idled:Connect(function()
	if not (live and CONFIG.antiAfk) then return end
	pcall(function()
		local vu = game:GetService("VirtualUser")
		vu:CaptureController()
		vu:ClickButton2(Vector2.new())
	end)
end)

------------------------------------------------------------------- debug -----

_G.__BUILDZOMBIES_DBG = {
	CONFIG = CONFIG, STATE = STATE, INV = INV,
	readCash = readCash, readRecord = readRecord, readBuild = readBuild,
	doRun = doRun, doRolls = doRolls, rollStation = rollStation, doBuild = doBuild,
	upgradeInPlace = upgradeInPlace, addWeapons = addWeapons, wanted = wanted,
	doSkills = doSkills, doCodes = doCodes, doQuests = doQuests,
	score = score, group = group, bestSpare = bestSpare, freeCellFor = freeCellFor,
	skillOwned = skillOwned, targetSpeed = targetSpeed,
	applyGhosts = applyGhosts, restoreGhosts = restoreGhosts, isObstacle = isObstacle, refreshRayFilter = refreshRayFilter,
}

--------------------------------------------------------------------- panel -----

local UI = (_G.__SEL and _G.__SEL.ui) or loadstring(readfile("ui-template.lua"))()
UI.config("buildzombies", CONFIG)
applyAntiAfk()

local win = UI.Window({
	name = "BuildZombies",
	title = "BUILD",
	accentTitle = "ZOMBIES",
	subtitle = "seltonmt",
	badge = "◆",
})
_G.__BUILDZOMBIES_GUI = win.gui

local function toggle(card, text, key, hint, tone, onChange)
	return card:Toggle(text, CONFIG[key], function(value)
		CONFIG[key] = value
		if onChange then onChange(value) end
	end, hint, tone)
end

-- FARM ------------------------------------------------------------------------
local farmPage = win:Page("FARM", UI.icon.bolt)

local runCard = farmPage:Card("DRIVING", 1):Accent()
toggle(runCard, "Auto Drive", "autoRun", "spawns the car, drives the road, ends the run, repeats")
runCard:Slider("Speed (studs/s)", 40, 200, CONFIG.speed, function(v) CONFIG.speed = v end,
	"100 is safe; above ~110 the server corrects the car inside zombie zones")
toggle(runCard, "Adaptive speed", "adaptive", "slows down after an early correction, speeds back up after clean runs")
toggle(runCard, "Drive through obstacles", "ghostObstacles", "rocks, blocks and walls on the track lose their collision, only on your screen",
	nil, function(on) if on then task.spawn(applyGhosts) else restoreGhosts() end end)
toggle(runCard, "End run on stall", "endOnStall", "ends the run when the zombies stop the car instead of waiting to die")
runCard:Button("Drive once", function() task.spawn(doRun, true) end)

local runOut = farmPage:Card("RUNS", 2):Readout(8)
local sessionOut = farmPage:Card("THIS SESSION", 2):Readout(7)

-- ROLL ------------------------------------------------------------------------
local rollPage = win:Page("ROLL", UI.icon.star)

local stationCard = rollPage:Card("ROLL STATIONS", 1):Accent()
toggle(stationCard, "Auto Roll", "autoRoll", "walks to the roll machines between runs; rolling is free")
toggle(stationCard, "Roll Blocks station", "rollBlocks", "blocks, engines, fuel tanks, wheels")
toggle(stationCard, "Roll Weapons station", "rollWeapons", "guns, push bars, launchers")
stationCard:Stepper("Rolls per cycle",
	function() return tostring(CONFIG.rollsPerCycle) end,
	function(delta) CONFIG.rollsPerCycle = math.clamp(CONFIG.rollsPerCycle + delta, 1, 30) end,
	"rolls per station between two runs, one every ~2.6s")

local catCard = rollPage:Card("BLOCKS STATION POOL", 1)
toggle(catCard, "Blocks", "catBlock", "armour: more car health", nil, function() task.spawn(applyCategories) end)
toggle(catCard, "Engines", "catEngine", "top speed and power", nil, function() task.spawn(applyCategories) end)
toggle(catCard, "Fuel tanks", "catFuel", "run length: capacity / drain", nil, function() task.spawn(applyCategories) end)
toggle(catCard, "Wheels", "catWheel", "support and grip", nil, function() task.spawn(applyCategories) end)

local buyCard = rollPage:Card("BUYING", 2):Accent()
toggle(buyCard, "Auto Buy upgrades", "autoBuy", "buys a rolled part only if it beats what the car already has")
toggle(buyCard, "Hold rare upgrades", "holdRare", "keeps an unaffordable upgrade on display and farms runs for it")
buyCard:Stepper("Hold up to",
	function() return tostring(CONFIG.holdRuns) .. " runs" end,
	function(delta) CONFIG.holdRuns = math.clamp(CONFIG.holdRuns + delta, 1, 100) end,
	"only hold a part that costs at most this many runs of cash")
local holdLabel = buyCard:Label("hold -")
buyCard:Button("Roll now", function() task.spawn(doRolls, true) end)

-- BUILD -----------------------------------------------------------------------
local buildPage = win:Page("BUILD", UI.icon.pickaxe)

local buildCard = buildPage:Card("CAR", 1):Accent()
toggle(buildCard, "Auto Equip upgrades", "autoBuild", "swaps a better owned part into the same cell of the car")
toggle(buildCard, "Mount weapons", "addWeapons", "puts the best owned weapons into free weapon slots")
buildCard:Button("Apply now", function() task.spawn(doBuild) end)

local carOut = buildPage:Card("CAR STATS", 2):Readout(8)

-- SKILLS ----------------------------------------------------------------------
local skillPage = win:Page("SKILLS", UI.icon.chart)

local skillCard = skillPage:Card("SKILL TREE", 1):Accent()
toggle(skillCard, "Auto Skills", "autoSkills", "weapon slots, damage, luck, golden rolls - in that order")
skillCard:Slider("Skill budget %", 10, 100, math.floor(CONFIG.skillShare * 100),
	function(v) CONFIG.skillShare = v / 100 end, "a skill may cost at most this share of the cash")
local skillLabel = skillCard:Label("next -")
skillCard:Button("Buy skills now", function() task.spawn(doSkills) end)

-- REWARDS ---------------------------------------------------------------------
local rewPage = win:Page("REWARDS", UI.icon.bag)

local rewCard = rewPage:Card("REWARDS", 1):Accent()
toggle(rewCard, "Auto Redeem Codes", "autoCodes", "every active code once, including the distance-gated ones")
toggle(rewCard, "Auto Claim Quests", "autoQuests", "weekly quests and offline cash")
toggle(rewCard, "Anti AFK", "antiAfk", "stops the game's 15-minute idle rejoin", nil, function() applyAntiAfk() end)
rewCard:Button("Redeem codes now", function() task.spawn(doCodes) end)

pcall(function() win:Home() end)
pcall(function() win:Settings() end)

win:SetMaster(CONFIG.auto, "Auto Farm", "roll, buy, build, drive - the whole loop")
win:OnMaster(function(on) CONFIG.auto = on end)
win:Refresh()

--------------------------------------------------------------------- loops -----

-- One orchestrator: the character can be at the roll machines OR in the car,
-- never both, so rolling, building and driving take turns in one thread.
task.spawn(function()
	readCash()
	readRecord()
	refreshCarStats()
	while alive() do
		if CONFIG.auto then
			if CONFIG.autoRoll then pcall(doRolls) end
			if CONFIG.autoBuild or CONFIG.addWeapons then pcall(doBuild) end
			if CONFIG.autoSkills then pcall(doSkills) end
			if CONFIG.autoRun then
				local ok, err = pcall(doRun)
				if not ok then
					RunService:UnbindFromRenderStep(BIND)
					note("run error: " .. tostring(err))
					task.wait(2)
				end
			else
				task.wait(1)
			end
		else
			STATE.phase = "idle"
			task.wait(1)
		end
	end
	pcall(function() RunService:UnbindFromRenderStep(BIND) end)
	pcall(function() invConn:Disconnect() end)
	pcall(function() confirmConn:Disconnect() end)
	pcall(function() idleConn:Disconnect() end)
end)

-- Codes and quests on a slow beat, independent of the loop above.
task.spawn(function()
	task.wait(5)
	while alive() do
		if CONFIG.auto and CONFIG.autoCodes then pcall(doCodes) end
		if CONFIG.auto and CONFIG.autoQuests then pcall(doQuests) end
		task.wait(120)
	end
end)

local function nextSkillText()
	for _, id in ipairs(SKILL_ORDER) do
		local node = skillNode(id)
		if node and not skillOwned[id] and (node.Parent == nil or skillOwned[node.Parent]) then
			return string.format("%s  %s", id, fmt(node.Cost or 0))
		end
	end
	return "all bought"
end

-- UI refresh.
task.spawn(function()
	while alive() do
		local hours = math.max((os.clock() - STATE.sessionStart) / 3600, 1 / 3600)
		local perHour = STATE.runCash / hours
		local plot = myPlot()
		STATE.plot = plot and plot.Name or "-"

		win:SetStatus(string.format("%s cash   best %s studs   %s/h   %s",
			fmt(STATE.cash), fmt(STATE.bestDist), fmt(perHour), STATE.phase))
		win:SetStat(1, fmt(STATE.cash), "cash")
		win:SetStat(2, fmt(math.max(STATE.record, STATE.bestDist)), "record")
		win:SetStat(3, fmt(perHour), "per hour")

		local holds = {}
		for station, h in pairs(STATE.hold) do
			table.insert(holds, string.format("%s %s", displayName(h.id), fmt(h.cost)))
		end
		holdLabel:set(#holds > 0 and ("holding: " .. table.concat(holds, ", ")) or "hold: nothing")
		skillLabel:set("next: " .. nextSkillText())

		runOut:set({
			"RUNS",
			string.format("  runs       %d", STATE.runs),
			string.format("  last       %s studs  +%s", fmt(STATE.lastDist), fmt(STATE.lastRunCash)),
			string.format("  best       %s studs", fmt(STATE.bestDist)),
			string.format("  speed      %s studs/s", fmt(targetSpeed(0))),
			string.format("  snaps      %d last run", STATE.snaps),
			string.format("  phase      %s", STATE.phase),
			"NOTE  " .. tostring(STATE.note),
		})
		sessionOut:set({
			"SESSION",
			string.format("  earned     %s  (%s/h)", fmt(STATE.runCash), fmt(perHour)),
			string.format("  rolls      %d", STATE.rolls),
			string.format("  bought     %d", STATE.bought),
			string.format("  swaps %d   weapons %d", STATE.swaps, STATE.weaponsAdded),
			string.format("  skills %d  codes %d", STATE.skills, STATE.codes),
			string.format("  plot       %s", STATE.plot),
		})

		local spareLines = {}
		for id, n in pairs(INV) do
			if (n or 0) > 0 then table.insert(spareLines, string.format("%s x%d", displayName(id), n)) end
		end
		table.sort(spareLines)
		carOut:set({
			"CAR",
			string.format("  top speed  %s", fmt(STATE.topSpeed)),
			string.format("  fuel time  %ss", fmt(STATE.fuelTime)),
			string.format("  parts      %d", STATE.carParts),
			string.format("  weapons    %s", STATE.support),
			"SPARE",
			"  " .. (table.concat(spareLines, ", "):sub(1, 60)),
			"  " .. (table.concat(spareLines, ", "):sub(61, 120)),
		})

		task.wait(1)
	end
end)

-- Keep the exact cash fresh for the header while idle.
task.spawn(function()
	while alive() do
		if not CONFIG.auto then readCash() end
		task.wait(5)
	end
end)
