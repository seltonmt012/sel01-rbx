--!nocheck
-- [Drill Blocks for Brainrots] - brainrot hunter, by seltonmt
--
-- Place 78177131121429. What the game does: drill blocks, brainrots drop into
-- workspace.Items, you carry one to your base, drop it on a slot, and it pays
-- money per second forever.
--
-- Findings this is built on, all measured through the bridge:
--
--   * Nothing here runs on RemoteEvents. Pickup, placing, grabbing and stealing
--     are all ProximityPrompts, which reach the server directly - a namecall and
--     a FireServer hook both stayed empty through a full manual pickup.
--   * A prompt only fires if the SERVER sees the character within
--     MaxActivationDistance (10). A one-shot CFrame write is not enough: the
--     position has to be held for a couple of seconds on Heartbeat, then
--     fireproximityprompt goes through. That was the whole difference between
--     "nothing happens" and the item vanishing into the character.
--   * Value comes from ItemsConfigurations.BaseMoney times the mutation
--     multiplier (Gold 1.5, Diamond 2, Galaxy 2.5, Lava 3, Rainbow 3.5) and
--     scales hard with Level - ItemsHelper.GetSell(2000, 50) is 112 million
--     against 2000 at level 1. MaxLevel is 50.
--   * Some item prompts are Enabled = false (locked area), so the target picker
--     only ever considers enabled ones.
--   * TeleportToBase is a plain RemoteEvent and works from anywhere.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

local plr = Players.LocalPlayer

local CONFIG = {
	autoFarm = false,      -- hunt -> carry -> place, in a loop
	killBlocks = false,    -- clear MiningBlocks so the map is walkable
	-- No autoCollect toggle: income lands in the balance on its own (measured
	-- 7.3Qa -> 11.3Qa while the character stood still and every loop was off).
	-- The only touchable pads in the base are StarterPack and AutoCollect, and
	-- both SELL something - an earlier version fired the AutoCollect pad and
	-- spent ~660T before it was caught. Nothing in here touches them again.
	replaceWeak = true,    -- when the base is full, swap out the worst earner
	autoCollect = true,    -- touch every slot's Money part to bank what pooled
	collectEvery = 45,     -- seconds between collection rounds
	buyStrength = true,    -- strength is the rebirth gate, so it comes first
	buyCarry = true,       -- more carry means more brainrots per trip
	buySpeed = true,
	upgradeBrainrots = true,   -- press the Level button on every placed brainrot
	upgradeHouse = true,   -- raise the house level: every level opens more slots
	autoRebirth = false,   -- resets strength, so it stays off until asked for
	spendFraction = 0.5,   -- never spend more than half the balance on one step
	maxBuysPerRound = 800, -- the server accepts these back to back; the only
	                       -- reason to stop is running out of money
	upgradeEvery = 1,      -- seconds between upgrade rounds (each buy is confirmed)
	minScore = 0,          -- ignore brainrots below this income score
	settleTime = 2.5,      -- seconds the position is held before firing a prompt
	scanInterval = 3,
}

local STATE = {
	money = "0", rebirths = 0, mps = "0",
	carrying = "-", target = "-", targetScore = 0,
	picked = 0, placed = 0, trips = 0, swaps = 0, collects = 0, earned = 0, upgrades = 0, brainrotUpgrades = 0,
	itemsSeen = 0, freeSlots = 0, phase = "idle", note = "-",
	uiOwner = "-",
}

_G.__DRILL = (_G.__DRILL or 0) + 1
local generation = _G.__DRILL
if _G.__DRILL_GUI then pcall(function() _G.__DRILL_GUI:Destroy() end) end

local Remotes = ReplicatedStorage:WaitForChild("Network", 10):WaitForChild("RemoteEvents", 10)
local itemsConfig = require(ReplicatedStorage.Configurations.Modules.ItemsConfigurations)
local mutationsConfig = require(ReplicatedStorage.Configurations.Modules.MutationsConfigurations)
local itemsHelper = require(ReplicatedStorage.Configurations.Modules.ItemsHelper)

local itemsFolder = workspace:WaitForChild("Items", 10)
local basesFolder = workspace:WaitForChild("Bases", 10)

local function shortNumber(n)
	n = tonumber(n) or 0
	for _, unit in ipairs({ { 1e12, "T" }, { 1e9, "B" }, { 1e6, "M" }, { 1e3, "K" } }) do
		if n >= unit[1] then return string.format("%.1f%s", n / unit[1], unit[2]) end
	end
	return tostring(math.floor(n))
end

local function rootPart()
	local char = plr.Character
	return char and char:FindFirstChild("HumanoidRootPart")
end

-- Position holding ------------------------------------------------------------
-- The server validates prompt distance against its own copy of the character, so
-- the client has to sit still at the destination long enough for that copy to
-- catch up. Writing the CFrame every Heartbeat also survives the game nudging
-- the character back.

local function holdAt(position, seconds)
	local hrp = rootPart()
	if not hrp then return false end

	-- same rules as newHold below: one hold at a time, no stored velocity
	if _G.__DRILL_HOLD then pcall(function() _G.__DRILL_HOLD:Disconnect() end) end
	local target = CFrame.new(position)
	local connection
	connection = RunService.Heartbeat:Connect(function()
		if _G.__DRILL ~= generation then connection:Disconnect() return end
		local root = rootPart()
		if root then
			root.CFrame = target
			root.AssemblyLinearVelocity = Vector3.zero
			root.AssemblyAngularVelocity = Vector3.zero
		end
	end)
	_G.__DRILL_HOLD = connection

	task.wait(seconds or CONFIG.settleTime)
	connection:Disconnect()
	if _G.__DRILL_HOLD == connection then _G.__DRILL_HOLD = nil end
	local root = rootPart()
	if root then root.AssemblyLinearVelocity = Vector3.zero end
	return true
end

-- Fires a prompt after parking the character next to it.
--
-- Order matters: a slot's Place prompt is Enabled only once the game sees the
-- player standing there holding something, so checking Enabled before moving
-- always failed and the placement silently did nothing. Move first, wait for the
-- prompt to come alive, then fire - all while still holding the position.
-- ONE position hold at a time, across re-executes. Two holds alive at once pulled
-- the body between two points every frame - 81 jumps of 150+ studs in three
-- seconds, the character flicking between the base and some old target in the
-- void (2026-09-26). A new hold kills the previous one, and a hold from an older
-- generation of this script ends itself on the next frame.
local function newHold(getPos)
	if _G.__DRILL_HOLD then pcall(function() _G.__DRILL_HOLD:Disconnect() end) end
	local conn
	conn = RunService.Heartbeat:Connect(function()
		if _G.__DRILL ~= generation then conn:Disconnect() return end
		local root = rootPart()
		local pos = getPos()
		if root and pos then
			root.CFrame = CFrame.new(pos)
			-- Kill the velocity every frame. Physics keeps integrating gravity and
			-- collisions under a pinned CFrame, and the moment the hold let go
			-- that stored speed FLUNG the character far away ("every time we
			-- place something it flings us away and we get stuck", 2026-09-26).
			root.AssemblyLinearVelocity = Vector3.zero
			root.AssemblyAngularVelocity = Vector3.zero
		end
	end)
	_G.__DRILL_HOLD = conn
	-- the caller disconnects through this wrapper so the release is clean too
	return {
		Disconnect = function()
			pcall(function() conn:Disconnect() end)
			if _G.__DRILL_HOLD == conn then _G.__DRILL_HOLD = nil end
			local root = rootPart()
			if root then
				root.AssemblyLinearVelocity = Vector3.zero
				root.AssemblyAngularVelocity = Vector3.zero
			end
		end,
	}
end

-- FLING GUARD. Measured 2026-09-26: the character left the map at 11,300,000
-- studs/s and ended 1.38 BILLION studs out, long after every hold had ended -
-- the carried brainrot tool overlapped slot geometry and the physics solver
-- ejected the whole assembly. Two defences:
--   * while a hold is active the character (and the tool in hand) does not
--     collide, so nothing can overlap at all
--   * a watchdog snaps the body back to the last calm position the moment its
--     speed is absurd or it is far outside the map
local lastSafe
do
	local guard
	guard = RunService.Stepped:Connect(function()
		if _G.__DRILL ~= generation then guard:Disconnect() return end
		local char = plr.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if not root then return end
		if _G.__DRILL_HOLD then
			_G.__DRILL_NOCLIP = _G.__DRILL_NOCLIP or {}
			for _, p in ipairs(char:GetDescendants()) do
				if p:IsA("BasePart") then
					if _G.__DRILL_NOCLIP[p] == nil then _G.__DRILL_NOCLIP[p] = p.CanCollide end
					p.CanCollide = false
				end
			end
		elseif _G.__DRILL_NOCLIP then
			for p, was in pairs(_G.__DRILL_NOCLIP) do
				pcall(function() if p.Parent then p.CanCollide = was end end)
			end
			_G.__DRILL_NOCLIP = nil
		end
		local speed = root.AssemblyLinearVelocity.Magnitude
		if speed > 400 or root.Position.Magnitude > 50000 then
			root.AssemblyLinearVelocity = Vector3.zero
			root.AssemblyAngularVelocity = Vector3.zero
			if lastSafe then root.CFrame = lastSafe end
			STATE.flings = (STATE.flings or 0) + 1
			STATE.note = "fling caught and undone"
		elseif speed < 120 and root.Position.Magnitude < 50000 then
			lastSafe = root.CFrame
		end
	end)
end

local function usePrompt(prompt, position)
	if not prompt then return false end

	local hold = newHold(function() return position end)

	local deadline = os.clock() + CONFIG.settleTime + 2
	local ready = false
	while os.clock() < deadline do
		if prompt.Enabled then ready = true break end
		task.wait(0.2)
	end

	if not ready then
		hold:Disconnect()
		return false
	end

	task.wait(CONFIG.settleTime)      -- let the server's copy catch up

	-- Exactly one press. These prompts toggle: the second fire dropped the
	-- brainrot again, which is why auto farm looked like it picked things up and
	-- immediately let go.
	fireproximityprompt(prompt)
	task.wait(1.2)
	hold:Disconnect()
	return true
end

-- Brainrots -------------------------------------------------------------------

local function mutationMultiplier(name)
	local entry = mutationsConfig[name or "Normal"]
	return (entry and entry.Multiplier) or 1
end

-- Income score: base income times mutation, with the level bonus folded in so a
-- level 30 common can outrank a level 1 rare.
local function scoreOf(model)
	local config = itemsConfig[model.Name]
	if not config then return 0 end

	local level = tonumber(model:GetAttribute("Level")) or 1
	local base = config.BaseMoney or 0
	local score = base * mutationMultiplier(model:GetAttribute("Mutation"))

	local ok, levelled = pcall(itemsHelper.GetSell, base, level)
	if ok and type(levelled) == "number" and levelled > 0 then
		score = levelled * mutationMultiplier(model:GetAttribute("Mutation"))
	end
	return score
end

local function promptOf(model)
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("ProximityPrompt") and descendant.Enabled then
			return descendant
		end
	end
	return nil
end

-- Best pickable brainrot currently lying in the world.
local function bestItem()
	local best, bestScore, bestPrompt
	local seen = 0

	for _, model in ipairs(itemsFolder:GetChildren()) do
		if model:IsA("Model") then
			seen += 1
			local prompt = promptOf(model)
			if prompt then
				local score = scoreOf(model)
				if score >= CONFIG.minScore and (not bestScore or score > bestScore) then
					best, bestScore, bestPrompt = model, score, prompt
				end
			end
		end
	end

	STATE.itemsSeen = seen
	return best, bestScore or 0, bestPrompt
end

-- What the character is carrying, if anything. The brainrot is reparented under
-- the character, next to EquippedShovel.
-- Brainrots are TOOLS now (game update): with Carry > 1 the others wait in the
-- Backpack, and only the one in hand can be placed. So when the hand is empty
-- but the backpack still holds a brainrot, it is equipped here - otherwise every
-- extra carried brainrot was left in the backpack and never placed.
local function brainrotTool(container)
	for _, t in ipairs(container and container:GetChildren() or {}) do
		if t:IsA("Tool") and itemsConfig[t.Name] then return t end
	end
	return nil
end

local function carriedModel()
	local char = plr.Character
	if not char then return nil end
	for _, descendant in ipairs(char:GetDescendants()) do
		if (descendant:IsA("Model") or descendant:IsA("Tool")) and descendant ~= char then
			if itemsConfig[descendant.Name] then return descendant end
		end
	end
	local waiting = brainrotTool(plr:FindFirstChild("Backpack"))
	local hum = char:FindFirstChildOfClass("Humanoid")
	if waiting and hum then
		pcall(function() hum:EquipTool(waiting) end)
		task.wait(0.3)
		if waiting.Parent == char then return waiting end
	end
	return nil
end

-- Base ------------------------------------------------------------------------

local myBase = nil

-- Ownership is written on the base's Board: it renders the owner's name next to
-- the income rate. Picking the nearest base after a TeleportToBase looked right
-- but lands on a neighbour's plot whenever the spawns sit close together.
local function findBase()
	if myBase and myBase.Parent then return myBase end

	for _, base in ipairs(basesFolder:GetChildren()) do
		local board = base:FindFirstChild("Board")
		if board then
			for _, label in ipairs(board:GetDescendants()) do
				if label:IsA("TextLabel") and label.Text == plr.Name then
					myBase = base
					STATE.note = "base " .. base.Name .. " (" .. plr.Name .. ")"
					return myBase
				end
			end
		end
	end

	STATE.note = "own base not found"
	return nil
end

-- A slot whose Place prompt is live. Only the slot the game itself offers is
-- used, so locked and occupied ones are skipped without guessing.
local function freeSlot()
	local base = findBase()
	if not base then return nil end

	local slots = base:FindFirstChild("Slots")
	if not slots then return nil end

	-- Placed brainrots are not parented into the slot - nothing with an item name
	-- exists anywhere under Bases, yet the base earns money. The reliable signal
	-- is the slot's own Money billboard: occupied slots render an income figure,
	-- empty ones have no text at all.
	local function isOccupied(slot)
		local money = slot:FindFirstChild("Money")
		if not money then return false end
		for _, label in ipairs(money:GetDescendants()) do
			if label:IsA("TextLabel") and label.Text ~= "" and label.Text ~= "0" then
				return true
			end
		end
		return false
	end

	-- owned floors only: a locked floor's slots look empty forever (see
	-- placeCarried); the ground floor is the lowest spawn height in the base
	local groundY = math.huge
	for _, slot in ipairs(slots:GetChildren()) do
		local sp = slot:FindFirstChild("Spawn")
		if sp then groundY = math.min(groundY, sp.Position.Y) end
	end

	local free = 0
	local pick, pickPrompt
	for _, slot in ipairs(slots:GetChildren()) do
		local prompt = slot:FindFirstChild("PlaceProximityPrompt", true)
		local spawn = slot:FindFirstChild("Spawn")
		local owned = prompt and (prompt.Enabled or (spawn and spawn.Position.Y - groundY < 8))
		if prompt and spawn and owned and not isOccupied(slot) and not slot:GetAttribute("BigSlot") then
			free += 1
			if not pick then pick, pickPrompt = slot, prompt end
		end
	end

	STATE.freeSlots = free
	return pick, pickPrompt
end

-- Reads the income figure a slot renders, e.g. "$2.6T", as a number so placed
-- brainrots can be ranked against a candidate lying in the world.
local SUFFIXES = { K = 1e3, M = 1e6, B = 1e9, T = 1e12, Qa = 1e15, Qi = 1e18, Sx = 1e21 }

local function parseMoney(text)
	if type(text) ~= "string" then return 0 end
	local number, suffix = text:match("%$?([%d%.]+)%s*(%a*)")
	number = tonumber(number)
	if not number then return 0 end
	return number * (SUFFIXES[suffix] or 1)
end

local function slotIncome(slot)
	local money = slot:FindFirstChild("Money")
	local best = 0
	for _, label in ipairs(money and money:GetDescendants() or {}) do
		if label:IsA("TextLabel") then
			-- The billboard also carries the offline earnings line; the income
			-- is the largest figure on it.
			best = math.max(best, parseMoney(label.Text))
		end
	end
	return best
end

-- The BASE value of a brainrot: config BaseMoney times its mutation, with no
-- level. The slot's income figure includes the upgrades, so ranking by it kept a
-- weak brainrot that had been levelled up and threw a far better new find away
-- ("do not be fooled just because it was upgraded", 2026-09-26). Levels can be
-- bought again; the base value cannot.
local function baseScore(name, mutation)
	local config = itemsConfig[name]
	if not config then return 0 end
	return (config.BaseMoney or 0) * mutationMultiplier(mutation)
end

-- Placed brainrots are loose models directly in the workspace, named after the
-- item and standing on their slot's Spawn - there is no link from the slot. The
-- one closest to the spawn (within a few studs) is that slot's brainrot. Its
-- mutation is read from its own labels when one of them names a mutation.
local function placedModels()
	local list = {}
	for _, m in ipairs(workspace:GetChildren()) do
		if m:IsA("Model") and itemsConfig[m.Name] then list[#list + 1] = m end
	end
	return list
end

local function mutationOfModel(model)
	local attr = model:GetAttribute("Mutation")
	if attr and attr ~= "" then return attr end
	for _, l in ipairs(model:GetDescendants()) do
		if l:IsA("TextLabel") and mutationsConfig[l.Text] then return l.Text end
	end
	return nil
end

local function slotBrainrot(slot, models)
	local spawn = slot:FindFirstChild("Spawn")
	if not spawn then return nil end
	local best, bestD
	for _, m in ipairs(models) do
		local ok, pos = pcall(function() return m:GetPivot().Position end)
		if ok then
			local d = (Vector3.new(pos.X, 0, pos.Z) - Vector3.new(spawn.Position.X, 0, spawn.Position.Z)).Magnitude
			if d < 8 and (not bestD or d < bestD) then best, bestD = m, d end
		end
	end
	return best
end

-- Every occupied slot, weakest BASE value first. The base spans several floors
-- once the house is upgraded, so slots are gathered from the whole model rather
-- than a single level. Income stays as a fallback when no model can be matched.
local function occupiedSlots(base)
	local list = {}
	local models = placedModels()
	for _, slot in ipairs(base.Slots:GetChildren()) do
		local income = slotIncome(slot)
		if income > 0 then
			local model = slotBrainrot(slot, models)
			local value = model and baseScore(model.Name, mutationOfModel(model)) or 0
			table.insert(list, {
				slot = slot, income = income, name = slot.Name,
				brainrot = model and model.Name or "?",
				value = value > 0 and value or income,
			})
		end
	end
	table.sort(list, function(a, b) return a.value < b.value end)
	return list
end

-- Actions ---------------------------------------------------------------------

local function pickUp(model, prompt)
	local ok, pivot = pcall(function() return model:GetPivot().Position end)
	if not ok then return false end

	STATE.phase = "fetching " .. model.Name
	usePrompt(prompt, pivot + Vector3.new(0, 3, 3))

	if model.Parent == nil or carriedModel() then
		STATE.picked += 1
		STATE.carrying = model.Name
		return true
	end
	return false
end

local function placeCarried()
	local carried = carriedModel()
	if not carried then return false end

	-- No early "no free slot" return any more: with every slot taken the swap /
	-- sell path further down is exactly what has to run, and returning here kept
	-- the carrier walking around with a brainrot it could never get rid of.
	freeSlot()

	STATE.phase = "placing " .. carried.Name

	-- Two conditions have to hold at once, which is what made this fiddly:
	--   * the game only marks Place prompts Enabled while the carrier is inside
	--     the base area, so a slot far out on the plot never lights up
	--   * the server still enforces MaxActivationDistance (10) against the slot
	--     itself, and the far slots sit 36 studs from the base spawn
	-- Picking the closest slot to the base spawn that is currently enabled
	-- satisfies both, and the placement goes through on the first try.
	local base = findBase()
	local baseSpawn = base and base:FindFirstChild("Spawn")
	if not baseSpawn then return false end

	-- One continuous hold for the whole operation. Releasing it to scan turned
	-- every prompt dark again before a single candidate could be read, so the
	-- anchor point is simply moved while the connection stays alive.
	STATE.phase = "returning to base"
	local anchor = baseSpawn.Position + Vector3.new(0, 3, 0)
	local hold = newHold(function() return anchor end)

	task.wait(CONFIG.settleTime)

	-- Candidates are the empty slots, nearest first. A slot's prompt only turns
	-- Enabled once the character is actually standing on that slot, so the check
	-- happens after arriving, not while listing.
	local candidates = {}
	for _, candidate in ipairs(base.Slots:GetChildren()) do
		local live = candidate:FindFirstChild("PlaceProximityPrompt", true)
		local spawn = candidate:FindFirstChild("Spawn")
		local money = candidate:FindFirstChild("Money")
		local occupied = false
		for _, label in ipairs(money and money:GetDescendants() or {}) do
			if label:IsA("TextLabel") and label.Text ~= "" and label.Text ~= "0" then
				occupied = true
				break
			end
		end
		-- BIG SLOTs (3X CASH, UNSTEALABLE, one per floor) are a paid feature; their
		-- prompt never lights up for a normal account, and trying them first is
		-- what walked the carrier from slot to slot without placing anything.
		if live and spawn and not occupied and not candidate:GetAttribute("BigSlot") then
			table.insert(candidates, {
				prompt = live,
				position = spawn.Position,
				distance = (spawn.Position - baseSpawn.Position).Magnitude,
				name = candidate.Name,
			})
		end
	end
	-- Only slots on a floor the player OWNS. Floors 2 and 3 of the house exist
	-- for everyone but stay locked until bought, and their Place prompt never
	-- lights up; sorting purely by distance sent the carrier up onto those
	-- floors, hovering over slots it could never use ("it does not know which
	-- floors I have", 2026-09-26). Standing at the base, the game already marks
	-- the usable empty slots Enabled - that is the ownership test. If none is lit
	-- (the server has not caught up yet), fall back to the ground floor only.
	local lit = {}
	for _, c in ipairs(candidates) do
		if c.prompt.Enabled then lit[#lit + 1] = c end
	end
	if #lit == 0 then
		local groundY = math.huge
		for _, c in ipairs(candidates) do groundY = math.min(groundY, c.position.Y) end
		for _, c in ipairs(candidates) do
			if c.position.Y - groundY < 8 then lit[#lit + 1] = c end
		end
	end
	candidates = lit
	table.sort(candidates, function(a, b) return a.distance < b.distance end)
	STATE.freeSlots = #candidates

	-- Base full: clear space by grabbing the weakest earner, but only when the
	-- brainrot in hand is actually worth more than what is standing there.
	if #candidates == 0 and CONFIG.replaceWeak then
		local placed = occupiedSlots(base)
		local weakest = placed[1]
		-- base value against base value - levels do not count on either side
		local incoming = baseScore(carried.Name, carried:GetAttribute("Mutation"))
		if weakest and incoming > weakest.value then
			local spawn = weakest.slot:FindFirstChild("Spawn")
			local grab = weakest.slot:FindFirstChild("GrabProximityPrompt", true)
			if spawn and grab then
				STATE.note = string.format("swapping out %s (base %s) for %s (base %s)",
					weakest.brainrot, shortNumber(weakest.value), carried.Name, shortNumber(incoming))
				anchor = spawn.Position + Vector3.new(0, 3, 0)
				task.wait(CONFIG.settleTime)
				local swap = weakest.slot:FindFirstChild("SwapProximityPrompt", true)
				if swap and swap.Enabled then
					fireproximityprompt(swap)
					task.wait(1.2)
				end
				if not carriedModel() then
					hold:Disconnect()
					STATE.placed += 1
					STATE.trips += 1
					STATE.swaps += 1
					STATE.carrying = "-"
					return true
				end
			end
		else
			STATE.note = "base full, carried is not better"
		end
	end

	if #candidates == 0 then
		hold:Disconnect()
		-- Every slot taken and the find is not worth a swap: sell it instead of
		-- carrying it around forever (user rule, 2026-09-26). Tried the game's
		-- own sell remote in the shapes it plausibly takes; the carried model
		-- disappearing is the only proof that counts.
		local sell = Remotes:FindFirstChild("SellItem")
		if sell then
			for _, args in ipairs({ {}, { carried.Name }, { carried } }) do
				if not carriedModel() then break end
				pcall(function() sell:FireServer(table.unpack(args)) end)
				local gone = os.clock() + 1.2
				while carriedModel() and os.clock() < gone do task.wait(0.1) end
			end
		end
		if not carriedModel() then
			STATE.carrying = "-"
			STATE.sold = (STATE.sold or 0) + 1
			STATE.note = "base full - sold " .. carried.Name
			return true
		end
		STATE.note = "base full, could not sell " .. carried.Name
		return false
	end

	-- Per slot: wait only until ITS prompt lights up (the server has caught up with
	-- the position), press once, and move on the moment it does not light up. The
	-- old flat 2.5 s per slot made the carrier drift from slot to slot for ten
	-- seconds whenever the nearest ones were locked ("teleports slowly from slot to
	-- slot and does not place", 2026-09-26).
	local success = false
	for attempt = 1, math.min(8, #candidates) do
		local choice = candidates[attempt]
		anchor = choice.position + Vector3.new(0, 3, 0)   -- walk the hold over
		local lit = os.clock() + 1.5
		while not choice.prompt.Enabled and os.clock() < lit do task.wait(0.1) end
		if choice.prompt.Enabled then
			task.wait(0.25)
			fireproximityprompt(choice.prompt)   -- once; a second press undoes it
			local gone = os.clock() + 1.5
			while carriedModel() and os.clock() < gone do task.wait(0.1) end
		end

		if not carriedModel() then
			success = true
			STATE.note = "slot " .. choice.name
			break
		end
	end
	hold:Disconnect()

	if success then
		STATE.placed += 1
		STATE.trips += 1
		STATE.carrying = "-"
		STATE.note = "placed " .. carried.Name
		return true
	end

	STATE.note = "place timed out: " .. carried.Name
	return false
end

-- Money -----------------------------------------------------------------------

-- Collecting money.
--
-- Do NOT touch Bases.<n>.AutoCollect: that model is the shop pad that SELLS the
-- auto-collect upgrade, and firing its TouchInterests spends money. An earlier
-- version of this function did exactly that and the balance dropped from
-- 1.85e16 to 1.78e16 before it was caught.
--
-- What is known so far: CollectMoney and RequestCollectCash on their own change
-- nothing, the slot Money parts carry no TouchInterest, and walking the occupied
-- slots produced no measurable gain either. The exact numeric balance comes over
-- the Money RemoteEvent, which is the only reliable way to measure a change -
-- the leaderstats value is a rounded StringValue ("16.1Qa") and hides anything
-- smaller than its own precision.
--
-- Until the real trigger is identified this only walks the base, which is
-- harmless, and reports what it saw.
-- Exact balance straight from the Money channel; the leaderstats value is a
-- rounded string and hides anything below its own precision.
local liveMoney = nil
do
	local moneyEvent = Remotes:FindFirstChild("Money")
	if moneyEvent then
		moneyEvent.OnClientEvent:Connect(function(value)
			if type(value) == "number" then liveMoney = value end
		end)
	end
end

-- The Money RemoteEvent only fires when the balance changes, so right after an
-- execute it can be nil for a while. The leaderstats string is the fallback: it
-- is rounded ("5.9Qa") but good enough to decide whether something is
-- affordable. Without this every spend check compared against zero and nothing
-- was ever bought.
local function balance()
	if liveMoney and liveMoney > 0 then return liveMoney end
	local stats = plr:FindFirstChild("leaderstats")
	local money = stats and stats:FindFirstChild("Money")
	return money and parseMoney(tostring(money.Value)) or 0
end

-- Collecting: touch each slot's Money part.
--
-- How this was found: recording every server->client event during a manual run
-- showed CollectMoney(slotMoneyPart, brainrotModel) arriving in a 0.3s rhythm
-- while the player walked across their slots, each one paired with a Money
-- increase. Firing CollectMoney back at the server does nothing - it is a
-- confirmation channel, not the trigger. The trigger is the touch, and it pays
-- whatever that brainrot has pooled since the last pickup.
--
-- Never touch AutoCollect or StarterPack: those are the shop pads and firing
-- them spends money.
local function collect()
	local base = findBase()
	if not base then return false end
	if not firetouchinterest then return false end

	local hrp = rootPart()
	if not hrp then return false end

	-- One frame per slot is enough for the server to accept the touch; the held
	-- anchor and the third-of-a-second pauses were pure overhead. Twelve slots
	-- now take 1.6s instead of fifteen.
	local before = balance()

	-- Only occupied slots are worth walking to, and the server accepts the touch
	-- as soon as the character is next to that part - firing from the base spawn
	-- or from 75 studs away collected nothing, so the walk itself is required.
	local touched = 0
	for _, entry in ipairs(occupiedSlots(base)) do
		local money = entry.slot:FindFirstChild("Money")
		if money and money:IsA("BasePart") then
			hrp.CFrame = CFrame.new(money.Position + Vector3.new(0, 2, 0))
			hrp.AssemblyLinearVelocity = Vector3.zero
			task.wait()
			firetouchinterest(hrp, money, 0)
			firetouchinterest(hrp, money, 1)
			touched += 1
		end
	end
	task.wait(1)

	local gained = balance() - before
	STATE.collects += 1
	if gained > 0 then
		STATE.earned += gained
		STATE.note = string.format("collected %s from %d slots", shortNumber(gained), touched)
	else
		STATE.note = "collected, nothing pooled"
	end
	return true
end

-- The user's own snippet: drills spawn blocks that get in the way, so they are
-- cleared and kept cleared. Purely visual/pathing - it does not earn anything.
local blockConnection = nil
local function setBlockClearing(on)
	if on then
		local blocks = workspace:FindFirstChild("MiningBlocks")
		if not blocks then return end
		pcall(function() blocks:ClearAllChildren() end)
		if not blockConnection then
			blockConnection = blocks.ChildAdded:Connect(function(child)
				if CONFIG.killBlocks then pcall(function() child:Destroy() end) end
			end)
		end
	elseif blockConnection then
		blockConnection:Disconnect()
		blockConnection = nil
	end
end

-- Brainrot upgrades -----------------------------------------------------------
--
-- Every slot renders a SurfaceGui on its Level part holding an ImageButton, and
-- that button is the upgrade. Unlike the rest of this game's interface its
-- Activated signal IS reachable from here, so firing the connection works where
-- everything else failed: UpgradeItem:FireServer with the part, the model or the
-- Money part was ignored (that remote is a server->client confirmation), and
-- touching the Level part did nothing. Verified: slot 2 went "Level 1 > Level 2"
-- to "Level 2 > Level 3" on a single fire.
local function slotUpgradeButton(slot)
	local level = slot:FindFirstChild("Level")
	local gui = level and level:FindFirstChildOfClass("SurfaceGui")
	return gui and gui:FindFirstChild("Level")
end

local function slotUpgradeInfo(slot)
	local button = slotUpgradeButton(slot)
	if not button then return nil end

	-- The Limit label always reads "MAX"; it is the button's caption, not a
	-- state, and treating it as one blocked every upgrade. What actually says
	-- "there is another level" is the arrow in the Level label.
	local costLabel, levelLabel
	for _, label in ipairs(button:GetDescendants()) do
		if label:IsA("TextLabel") then
			if label.Name == "Money" then costLabel = label end
			if label.Name == "Level" then levelLabel = label end
		end
	end

	local levelText = levelLabel and tostring(levelLabel.Text) or ""
	return {
		button = button,
		cost = costLabel and parseMoney(costLabel.Text) or math.huge,
		costText = costLabel and costLabel.Text or "?",
		levelText = levelText,
		maxed = levelText ~= "" and not levelText:find(">"),
	}
end

-- Upgrades every placed brainrot as far as the balance allows, fired back to
-- back with a frame yield every 25 presses.
local function upgradeBrainrots()
	local base = findBase()
	if not base or not getconnections then return end

	local fired = 0
	for _, entry in ipairs(occupiedSlots(base)) do
		local info = slotUpgradeInfo(entry.slot)
		while info and not info.maxed do
			-- "FREE" parses to 0 and used to count as "no price read" - so the free
			-- first levels were never pressed (brainrot levels stayed at 0 all run)
			local free = tostring(info.costText):upper():find("FREE") ~= nil
			if not free and (info.cost <= 0 or info.cost > balance() * CONFIG.spendFraction) then break end

			local levelBefore = info.levelText
			for _, connection in pairs(getconnections(info.button.Activated)) do
				pcall(function() connection:Fire() end)
			end
			fired += 1
			if fired >= CONFIG.maxBuysPerRound then break end

			-- same rule as the stat buys: only continue once the level really moved
			local deadline = os.clock() + 0.5
			repeat
				task.wait(0.05)
				info = slotUpgradeInfo(entry.slot)
			until not info or info.levelText ~= levelBefore or os.clock() > deadline
			if not info or info.levelText == levelBefore then break end
			STATE.brainrotUpgrades += 1
		end
		if fired >= CONFIG.maxBuysPerRound then break end
	end

	if fired > 0 then
		STATE.note = string.format("upgraded brainrots x%d", fired)
	end
end

-- House level. The sign on the base (Base.Level.BaseLevelGui.Level, "Level 0 >
-- Level 1", $100K) raises the house and opens the next floor of slots - more
-- room for brainrots. Same kind of button as the slot levels: pressed through
-- its Activated connection and confirmed by the level text moving.
local function upgradeHouse()
	local base = findBase()
	if not base or not getconnections then return false end
	local part = base:FindFirstChild("Level")
	local gui = part and part:FindFirstChild("BaseLevelGui")
	local button = gui and gui:FindFirstChild("Level")
	if not button then return false end
	local levelLabel, costLabel
	for _, l in ipairs(button:GetDescendants()) do
		if l:IsA("TextLabel") then
			if l.Name == "Level" then levelLabel = l end
			if l.Name == "Money" then costLabel = l end
		end
	end
	local levelText = levelLabel and levelLabel.Text or ""
	if levelText == "" or not levelText:find(">") then return false end   -- maxed
	local costText = costLabel and costLabel.Text or ""
	local cost = parseMoney(costText)
	local free = costText:upper():find("FREE") ~= nil
	if not free and (cost <= 0 or cost > balance() * CONFIG.spendFraction) then return false end
	for _, connection in pairs(getconnections(button.Activated)) do
		pcall(function() connection:Fire() end)
	end
	local deadline = os.clock() + 1
	repeat task.wait(0.1) until (levelLabel and levelLabel.Text ~= levelText) or os.clock() > deadline
	if levelLabel and levelLabel.Text ~= levelText then
		STATE.note = "house " .. levelText .. " (" .. costText .. ")"
		return true
	end
	return false
end

-- Stat upgrades and rebirth ---------------------------------------------------
--
-- The upgrade panel's Buy buttons report zero connections because the game's UI
-- runs in Actor VMs, so they cannot be pressed from here. The remotes work
-- though - the catch is that they need the amount as an argument. Fired bare
-- they do nothing at all, which is why an earlier attempt looked like a dead
-- end. Verified: IncrementStrength(1) took 597 -> 598, IncrementCarry(1) took
-- Carry 1 -> 2, IncrementSpeed(1) took Speed 0 -> 1.

local function upgradePanel()
	local gui = plr.PlayerGui:FindFirstChild("Gui")
	local frames = gui and gui:FindFirstChild("Frames")
	local upgrades = frames and frames:FindFirstChild("Upgrades")
	return upgrades and upgrades:FindFirstChild("Container")
end

-- Reads a row of the upgrade panel: what it costs and where the stat stands.
local function upgradeRow(rowName, statName)
	local container = upgradePanel()
	local row = container and container:FindFirstChild(rowName)
	if not row then return nil end

	local costLabel = row:FindFirstChild("Cost", true)
	local currentLabel = row:FindFirstChild("Current" .. statName, true)
	return {
		cost = costLabel and parseMoney(costLabel.Text) or math.huge,
		current = currentLabel and (tonumber(tostring(currentLabel.Text):match("%d+")) or 0) or 0,
		costText = costLabel and costLabel.Text or "?",
	}
end

-- Buys as many single steps as the balance allows, cheapest stat first. The cost
-- climbs after every purchase, so the row is re-read each time instead of
-- assuming the price stays put.
local function buyUpgrades()
	local plan = {
		{ row = "Jump1", stat = "Speed", remote = "IncrementSpeed", enabled = CONFIG.buySpeed },
		{ row = "Carry1", stat = "Carry", remote = "IncrementCarry", enabled = CONFIG.buyCarry },
		{ row = "Speed1", stat = "Strength", remote = "IncrementStrength", enabled = CONFIG.buyStrength },
	}

	for _, entry in ipairs(plan) do
		if entry.enabled then
			-- Fired back to back with no pacing. The only yield is one frame every
			-- 25 calls, purely so the client keeps rendering - the server takes
			-- them as fast as they arrive.
			local remote = Remotes:FindFirstChild(entry.remote)
			local fired = 0
			while remote and fired < CONFIG.maxBuysPerRound do
				local info = upgradeRow(entry.row, entry.stat)
				if not info or info.cost <= 0 or info.cost > balance() * CONFIG.spendFraction then break end

				remote:FireServer(1)          -- the amount argument is mandatory
				fired += 1
				-- Confirm before the next one. The cost label and the balance lag
				-- behind the server, so firing on stale numbers sent hundreds of
				-- refused buys a second - a wall of "Not enough money!" and heavy
				-- lag (2026-09-26). No rise inside 0.5 s = out of money, stop.
				local confirmed = false
				local deadline = os.clock() + 0.5
				repeat
					task.wait(0.05)
					local now = upgradeRow(entry.row, entry.stat)
					if now and now.current > info.current then confirmed = true end
				until confirmed or os.clock() > deadline
				if not confirmed then break end
				STATE.upgrades += 1
				STATE.note = string.format("%s -> %d (%s)", entry.stat, info.current + 1, info.costText)
			end
		end
	end
end

-- Rebirth. The panel spells out the gate as "Strength 599/200", so the numbers
-- are taken from there rather than from a config guess. It resets strength and
-- keeps the money multiplier, so it only fires once the requirement is met.
local function rebirthInfo()
	local gui = plr.PlayerGui:FindFirstChild("Gui")
	local frames = gui and gui:FindFirstChild("Frames")
	local panel = frames and frames:FindFirstChild("Rebirth")
	if not panel then return nil end

	for _, label in ipairs(panel:GetDescendants()) do
		if label:IsA("TextLabel") and label.Name == "Amount" then
			local have, need = tostring(label.Text):match("(%d+)%s*/%s*(%d+)")
			if have and need then
				return { have = tonumber(have), need = tonumber(need) }
			end
		end
	end
	return nil
end

local function tryRebirth()
	local info = rebirthInfo()
	if not info then return false end
	if info.have < info.need then
		STATE.note = string.format("rebirth at %d/%d strength", info.have, info.need)
		return false
	end

	local remote = Remotes:FindFirstChild("Rebirth")
	if not remote then return false end

	local before = tonumber(plr.leaderstats.Rebirths.Value) or 0
	remote:FireServer()
	task.wait(2)
	local after = tonumber(plr.leaderstats.Rebirths.Value) or 0
	if after > before then
		STATE.rebirths = after
		STATE.note = string.format("rebirth %d -> %d", before, after)
		return true
	end
	return false
end

-- Farm loop -------------------------------------------------------------------

local nextCollectAt = 0

local function farmStep()
	if carriedModel() then
		placeCarried()
		return
	end

	-- Money collection happens HERE, between trips with empty hands. It used to
	-- run in its own loop every 45 s and teleport the body across the slots while
	-- the farm was holding it somewhere else - the two fought, the character
	-- flicked far away and the placement loop got stuck ("teleports randomly far
	-- away, then stuck", 2026-09-26).
	if CONFIG.autoCollect and os.clock() >= nextCollectAt then
		nextCollectAt = os.clock() + CONFIG.collectEvery
		pcall(collect)
	end

	local model, score, prompt = bestItem()
	if not model then
		STATE.phase = "no target"
		STATE.target = "-"
		task.wait(1)
		return
	end

	STATE.target = string.format("%s (%s)", model.Name, shortNumber(score))
	STATE.targetScore = score

	-- Base full: only fetch what beats the weakest placed brainrot on BASE value,
	-- otherwise the trip ends in a sale of something just walked across the map.
	local base = findBase()
	if base and not freeSlot() and CONFIG.replaceWeak then
		local placed = occupiedSlots(base)
		local weakest = placed[1]
		local incoming = baseScore(model.Name, model:GetAttribute("Mutation"))
		if weakest and incoming <= weakest.value then
			STATE.phase = "base full"
			STATE.note = string.format("base full - best find %s (base %s) is not above %s (base %s)",
				model.Name, shortNumber(incoming), weakest.brainrot, shortNumber(weakest.value))
			task.wait(2)
			return
		end
	end

	if pickUp(model, prompt) then
		placeCarried()
	else
		STATE.note = "pickup failed: " .. model.Name
		task.wait(0.5)
	end
end

-- Data ------------------------------------------------------------------------

local function refreshStats()
	local stats = plr:FindFirstChild("leaderstats")
	if stats then
		local money = stats:FindFirstChild("Money")
		local rebirths = stats:FindFirstChild("Rebirths")
		STATE.money = money and tostring(money.Value) or "0"
		STATE.rebirths = rebirths and tonumber(rebirths.Value) or 0
	end

	local carried = carriedModel()
	STATE.carrying = carried and carried.Name or "-"
end

-- UI ---------------------------------------------------------------------------

-- The shared Selux panel (lib/ui-template.lua), like every other script. This
-- file shipped its own hand-built ScreenGui for months - reported 2026-09-26 as
-- "why does this one still have the old UI". Same switches, same logic.
local UI = (_G.__SEL and _G.__SEL.ui) or loadstring(readfile("ui-template.lua"))()
if _G.__DRILL_GUI then pcall(function() _G.__DRILL_GUI:Destroy() end) end
if _G.__DRILL_WIN then pcall(function() _G.__DRILL_WIN:Destroy() end) end
if UI.sweep then UI.sweep("DRILLBLOCKS") end
UI.config("drillblocks", CONFIG)
if (CONFIG.upgradeEvery or 0) < 1 then CONFIG.upgradeEvery = 1 end   -- old 0.2 s saves

local win = UI.Window({
	name = "DRILLBLOCKS",
	title = "DRILL", accentTitle = "BLOCKS", subtitle = "seltonmt",
	width = 820, height = 582,
})
_G.__DRILL_WIN = win

local MIN_STEPS = { 0, 1e6, 1e7, 1e8, 1e9, 5e9, 1e10, 5e10 }

local page = win:Page("FARMING", UI.icon and UI.icon.coin or nil)

local farmCard = page:Card("BRAINROTS", 1):Accent()
farmCard:Toggle("Auto farm brainrots", CONFIG.autoFarm, function(v) CONFIG.autoFarm = v end,
	"hunt the best brainrot, carry it home, put it on a slot - in a loop",
	UI.theme and UI.theme.warn)
farmCard:Toggle("Replace weakest when full", CONFIG.replaceWeak, function(v) CONFIG.replaceWeak = v end,
	"with every slot taken, swap out the worst earner for a better find")
farmCard:Stepper("Min score", function() return shortNumber(CONFIG.minScore) end,
	function(dir)
		local index = 1
		for i, v in ipairs(MIN_STEPS) do if CONFIG.minScore >= v then index = i end end
		CONFIG.minScore = MIN_STEPS[math.clamp(index + dir, 1, #MIN_STEPS)]
	end, "ignore brainrots earning less than this")
farmCard:Button("Fetch best brainrot now", function() task.spawn(farmStep) end)
farmCard:Button("Teleport to base", function()
	pcall(function() Remotes.TeleportToBase:FireServer() end)
end)

local mapCard = page:Card("MAP & MONEY", 2)
mapCard:Toggle("Clear mining blocks", CONFIG.killBlocks, function(v)
	CONFIG.killBlocks = v
	setBlockClearing(v)
end, "removes the blocks so the map is walkable")
mapCard:Toggle("Auto collect money", CONFIG.autoCollect, function(v) CONFIG.autoCollect = v end,
	"touches every slot's money part to bank what pooled")

local shopCard = page:Card("UPGRADES", 1)
shopCard:Toggle("Buy strength", CONFIG.buyStrength, function(v) CONFIG.buyStrength = v end,
	"strength is the rebirth gate, so it comes first")
shopCard:Toggle("Buy carry", CONFIG.buyCarry, function(v) CONFIG.buyCarry = v end)
shopCard:Toggle("Buy speed", CONFIG.buySpeed, function(v) CONFIG.buySpeed = v end)
shopCard:Toggle("Upgrade brainrots", CONFIG.upgradeBrainrots, function(v) CONFIG.upgradeBrainrots = v end,
	"presses the Level button on every placed brainrot, free levels included")
shopCard:Toggle("Upgrade house", CONFIG.upgradeHouse, function(v) CONFIG.upgradeHouse = v end,
	"raises the house level - each level opens another floor of slots")

local rebirthCard = page:Card("REBIRTH", 2)
rebirthCard:Toggle("Auto rebirth", CONFIG.autoRebirth, function(v) CONFIG.autoRebirth = v end,
	"resets strength - off until you want it", UI.theme and UI.theme.warn)

local statusOut = page:Card("STATUS", 0):Readout(7)

-- Loops -------------------------------------------------------------------------

local function loop(interval, key, fn)
	task.spawn(function()
		while _G.__DRILL == generation do
			if CONFIG[key] then pcall(fn) end
			task.wait(interval)
		end
	end)
end


-- Standalone collection only while the farm is OFF; with the farm on it is done
-- inside farmStep so the two never move the body at the same time.
task.spawn(function()
	while _G.__DRILL == generation do
		if CONFIG.autoCollect and not CONFIG.autoFarm then pcall(collect) end
		task.wait(CONFIG.collectEvery)
	end
end)

task.spawn(function()
	while _G.__DRILL == generation do
		if CONFIG.upgradeHouse then pcall(upgradeHouse) end
		pcall(buyUpgrades)
		if CONFIG.upgradeBrainrots then pcall(upgradeBrainrots) end
		if CONFIG.autoRebirth then pcall(tryRebirth) end
		task.wait(CONFIG.upgradeEvery)
	end
end)

task.spawn(function()
	while _G.__DRILL == generation do
		if CONFIG.autoFarm then
			pcall(farmStep)
		else
			STATE.phase = "idle"
			task.wait(0.5)
		end
		task.wait(0.2)
	end
end)

task.spawn(function()
	while _G.__DRILL == generation do
		pcall(refreshStats)
		task.wait(2)
	end
end)

task.spawn(function()
	while _G.__DRILL == generation do
		pcall(function()
			statusOut:set({
				string.format("  phase %s", tostring(STATE.phase)),
				string.format("  carrying %s   target %s", tostring(STATE.carrying), tostring(STATE.target)),
				string.format("  picked %d   placed %d   swaps %d   trips %d",
					STATE.picked, STATE.placed, STATE.swaps, STATE.trips),
				string.format("  items seen %d   free slots %d   collects %d",
					STATE.itemsSeen, STATE.freeSlots, STATE.collects),
				string.format("  upgrades %d   brainrot levels %d", STATE.upgrades, STATE.brainrotUpgrades),
				"  " .. tostring(STATE.note),
			})
			win:SetStat(1, "$" .. tostring(STATE.money), "money")
			win:SetStat(2, tostring(STATE.mps), "per sec")
			win:SetStat(3, tostring(STATE.rebirths), "rebirths")
			win:SetStatus(string.format("$%s   %s/s   rb %d   trips %d",
				tostring(STATE.money), tostring(STATE.mps), STATE.rebirths, STATE.trips))
		end)
		task.wait(0.5)
	end
end)

pcall(function()
	win:SetMaster(CONFIG.autoFarm, "Auto farm running")
	win:OnMaster(function(on) CONFIG.autoFarm = on end)
end)
pcall(function() win:Home() end)

_G.__DRILL_DBG = {
	CONFIG = CONFIG, STATE = STATE,
	bestItem = bestItem, pickUp = pickUp, placeCarried = placeCarried,
	freeSlot = freeSlot, findBase = findBase, farmStep = farmStep,
	carriedModel = carriedModel, scoreOf = scoreOf, collect = collect,
	liveMoney = function() return liveMoney end, balance = balance,
	buyUpgrades = buyUpgrades, tryRebirth = tryRebirth, upgradeBrainrots = upgradeBrainrots,
	slotUpgradeInfo = slotUpgradeInfo, upgradeRow = upgradeRow, rebirthInfo = rebirthInfo,
	occupiedSlots = occupiedSlots, slotIncome = slotIncome, parseMoney = parseMoney,
}

print("[drillblocks] by seltonmt - running (gen " .. generation .. ") - RightShift toggles the UI")
