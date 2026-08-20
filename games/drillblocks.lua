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
	autoRebirth = false,   -- resets strength, so it stays off until asked for
	spendFraction = 0.5,   -- never spend more than half the balance on one step
	maxBuysPerRound = 800, -- the server accepts these back to back; the only
	                       -- reason to stop is running out of money
	upgradeEvery = 0.2,    -- seconds between upgrade rounds
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

	local target = CFrame.new(position)
	local connection = RunService.Heartbeat:Connect(function()
		local root = rootPart()
		if root then root.CFrame = target end
	end)

	task.wait(seconds or CONFIG.settleTime)
	connection:Disconnect()
	return true
end

-- Fires a prompt after parking the character next to it.
--
-- Order matters: a slot's Place prompt is Enabled only once the game sees the
-- player standing there holding something, so checking Enabled before moving
-- always failed and the placement silently did nothing. Move first, wait for the
-- prompt to come alive, then fire - all while still holding the position.
local function usePrompt(prompt, position)
	if not prompt then return false end

	local hold = RunService.Heartbeat:Connect(function()
		local root = rootPart()
		if root then root.CFrame = CFrame.new(position) end
	end)

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
local function carriedModel()
	local char = plr.Character
	if not char then return nil end
	for _, descendant in ipairs(char:GetDescendants()) do
		if descendant:IsA("Model") and descendant ~= char then
			if itemsConfig[descendant.Name] then return descendant end
		end
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

	local free = 0
	local pick, pickPrompt
	for _, slot in ipairs(slots:GetChildren()) do
		local prompt = slot:FindFirstChild("PlaceProximityPrompt", true)
		local spawn = slot:FindFirstChild("Spawn")
		if prompt and spawn and not isOccupied(slot) then
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

-- Every occupied slot with what it earns, weakest first. The base spans several
-- floors once the house is upgraded, so slots are gathered from the whole model
-- rather than a single level.
local function occupiedSlots(base)
	local list = {}
	for _, slot in ipairs(base.Slots:GetChildren()) do
		local income = slotIncome(slot)
		if income > 0 then
			table.insert(list, { slot = slot, income = income, name = slot.Name })
		end
	end
	table.sort(list, function(a, b) return a.income < b.income end)
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

	local slot, prompt = freeSlot()
	if not slot then
		STATE.note = "no free slot"
		return false
	end

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
	local hold = RunService.Heartbeat:Connect(function()
		local root = rootPart()
		if root then root.CFrame = CFrame.new(anchor) end
	end)

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
		if live and spawn and not occupied then
			table.insert(candidates, {
				prompt = live,
				position = spawn.Position,
				distance = (spawn.Position - baseSpawn.Position).Magnitude,
				name = candidate.Name,
			})
		end
	end
	table.sort(candidates, function(a, b) return a.distance < b.distance end)
	STATE.freeSlots = #candidates

	-- Base full: clear space by grabbing the weakest earner, but only when the
	-- brainrot in hand is actually worth more than what is standing there.
	if #candidates == 0 and CONFIG.replaceWeak then
		local placed = occupiedSlots(base)
		local weakest = placed[1]
		local incoming = scoreOf(carried)
		if weakest and incoming > weakest.income then
			local spawn = weakest.slot:FindFirstChild("Spawn")
			local grab = weakest.slot:FindFirstChild("GrabProximityPrompt", true)
			if spawn and grab then
				STATE.note = string.format("swapping out slot %s (%s)", weakest.name, shortNumber(weakest.income))
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
		STATE.note = "base full"
		return false
	end

	local success = false
	for attempt = 1, math.min(4, #candidates) do
		local choice = candidates[attempt]
		anchor = choice.position + Vector3.new(0, 3, 0)   -- walk the hold over
		task.wait(CONFIG.settleTime)

		if choice.prompt.Enabled then
			fireproximityprompt(choice.prompt)   -- once; a second press undoes it
			task.wait(1.2)
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
			if info.cost <= 0 or info.cost > balance() * CONFIG.spendFraction then break end

			for _, connection in pairs(getconnections(info.button.Activated)) do
				pcall(function() connection:Fire() end)
			end
			fired += 1
			STATE.brainrotUpgrades += 1
			if fired % 25 == 0 then task.wait() end
			if fired >= CONFIG.maxBuysPerRound then break end

			info = slotUpgradeInfo(entry.slot)
		end
		if fired >= CONFIG.maxBuysPerRound then break end
	end

	if fired > 0 then
		STATE.note = string.format("upgraded brainrots x%d", fired)
	end
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
				STATE.upgrades += 1
				STATE.note = string.format("%s -> %d (%s)", entry.stat, info.current + 1, info.costText)
				if fired % 25 == 0 then task.wait() end
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

local function farmStep()
	if carriedModel() then
		placeCarried()
		return
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

local COLORS = {
	bg = Color3.fromRGB(15, 16, 20),
	header = Color3.fromRGB(22, 23, 29),
	panel = Color3.fromRGB(30, 32, 40),
	panelHover = Color3.fromRGB(38, 40, 50),
	on = Color3.fromRGB(72, 205, 130),
	off = Color3.fromRGB(58, 60, 70),
	text = Color3.fromRGB(232, 234, 240),
	dim = Color3.fromRGB(138, 142, 155),
	accent = Color3.fromRGB(255, 186, 90),
	warn = Color3.fromRGB(250, 176, 96),
	bad = Color3.fromRGB(232, 104, 104),
	line = Color3.fromRGB(44, 46, 56),
}

local function corner(parent, radius)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius or 6)
	c.Parent = parent
end

local gui = Instance.new("ScreenGui")
gui.Name = "DrillBlocks"
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
pcall(function() gui.Parent = (gethui and gethui()) or game:GetService("CoreGui") end)
if not gui.Parent then gui.Parent = plr:WaitForChild("PlayerGui", 10) end
_G.__DRILL_GUI = gui

local frame = Instance.new("Frame")
frame.Size = UDim2.fromOffset(340, 420)
frame.Position = UDim2.new(0, 20, 0.5, -210)
frame.BackgroundColor3 = COLORS.bg
frame.BorderSizePixel = 0
frame.Active = true
frame.Draggable = true
frame.Parent = gui
corner(frame, 12)

local stroke = Instance.new("UIStroke")
stroke.Color = COLORS.line
stroke.Parent = frame

local header = Instance.new("Frame")
header.Size = UDim2.new(1, 0, 0, 52)
header.BackgroundColor3 = COLORS.header
header.BorderSizePixel = 0
header.Parent = frame
corner(header, 12)

local headerFill = Instance.new("Frame")
headerFill.Size = UDim2.new(1, 0, 0, 12)
headerFill.Position = UDim2.new(0, 0, 1, -12)
headerFill.BackgroundColor3 = COLORS.header
headerFill.BorderSizePixel = 0
headerFill.Parent = header

local accentBar = Instance.new("Frame")
accentBar.Size = UDim2.fromOffset(3, 18)
accentBar.Position = UDim2.new(0, 12, 0, 9)
accentBar.BackgroundColor3 = COLORS.accent
accentBar.BorderSizePixel = 0
accentBar.Parent = header
corner(accentBar, 2)

local title = Instance.new("TextLabel")
title.Size = UDim2.new(0, 120, 0, 20)
title.Position = UDim2.new(0, 22, 0, 8)
title.BackgroundTransparency = 1
title.Text = "DRILL BLOCKS"
title.TextXAlignment = Enum.TextXAlignment.Left
title.TextColor3 = COLORS.text
title.Font = Enum.Font.GothamBold
title.TextSize = 13
title.Parent = header

local credit = Instance.new("TextLabel")
credit.Size = UDim2.fromOffset(120, 20)
credit.Position = UDim2.new(0, 140, 0, 8)
credit.BackgroundTransparency = 1
credit.Text = "by seltonmt"
credit.TextXAlignment = Enum.TextXAlignment.Left
credit.TextColor3 = COLORS.accent
credit.Font = Enum.Font.GothamMedium
credit.TextSize = 11
credit.Parent = header

local headline = Instance.new("TextLabel")
headline.Size = UDim2.new(1, -24, 0, 16)
headline.Position = UDim2.new(0, 22, 0, 28)
headline.BackgroundTransparency = 1
headline.Text = "idle"
headline.TextXAlignment = Enum.TextXAlignment.Left
headline.TextColor3 = COLORS.dim
headline.Font = Enum.Font.Gotham
headline.TextSize = 11
headline.Parent = header

local body = Instance.new("Frame")
body.Size = UDim2.new(1, -16, 1, -150)
body.Position = UDim2.new(0, 8, 0, 58)
body.BackgroundTransparency = 1
body.Parent = frame

local layout = Instance.new("UIListLayout")
layout.Padding = UDim.new(0, 5)
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Parent = body

local order = 0
local function nextOrder()
	order += 1
	return order
end

local function makeToggle(text, key, onChange, tone)
	local button = Instance.new("TextButton")
	button.Size = UDim2.new(1, -6, 0, 30)
	button.BackgroundColor3 = COLORS.panel
	button.BorderSizePixel = 0
	button.Text = ""
	button.AutoButtonColor = false
	button.LayoutOrder = nextOrder()
	button.Parent = body
	corner(button, 7)

	local mark = Instance.new("Frame")
	mark.Size = UDim2.fromOffset(3, 16)
	mark.Position = UDim2.new(0, 8, 0.5, -8)
	mark.BackgroundColor3 = CONFIG[key] and (tone or COLORS.on) or COLORS.off
	mark.BorderSizePixel = 0
	mark.Parent = button
	corner(mark, 2)

	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, -66, 1, 0)
	label.Position = UDim2.new(0, 18, 0, 0)
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextColor3 = tone or COLORS.text
	label.Font = Enum.Font.Gotham
	label.TextSize = 12
	label.Parent = button

	local pill = Instance.new("Frame")
	pill.Size = UDim2.fromOffset(34, 18)
	pill.Position = UDim2.new(1, -44, 0.5, -9)
	pill.BackgroundColor3 = CONFIG[key] and COLORS.on or COLORS.off
	pill.BorderSizePixel = 0
	pill.Parent = button
	corner(pill, 9)

	local knob = Instance.new("Frame")
	knob.Size = UDim2.fromOffset(14, 14)
	knob.Position = CONFIG[key] and UDim2.new(1, -16, 0, 2) or UDim2.new(0, 2, 0, 2)
	knob.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	knob.BorderSizePixel = 0
	knob.Parent = pill
	corner(knob, 7)

	button.MouseEnter:Connect(function()
		TweenService:Create(button, TweenInfo.new(0.12), { BackgroundColor3 = COLORS.panelHover }):Play()
	end)
	button.MouseLeave:Connect(function()
		TweenService:Create(button, TweenInfo.new(0.12), { BackgroundColor3 = COLORS.panel }):Play()
	end)
	button.MouseButton1Click:Connect(function()
		CONFIG[key] = not CONFIG[key]
		local info = TweenInfo.new(0.15, Enum.EasingStyle.Quad)
		TweenService:Create(pill, info, { BackgroundColor3 = CONFIG[key] and COLORS.on or COLORS.off }):Play()
		TweenService:Create(knob, info, {
			Position = CONFIG[key] and UDim2.new(1, -16, 0, 2) or UDim2.new(0, 2, 0, 2),
		}):Play()
		mark.BackgroundColor3 = CONFIG[key] and (tone or COLORS.on) or COLORS.off
		if onChange then onChange(CONFIG[key]) end
	end)
end

local function makeRow(labelText, getValue, onStep)
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, -6, 0, 30)
	row.BackgroundColor3 = COLORS.panel
	row.BorderSizePixel = 0
	row.LayoutOrder = nextOrder()
	row.Parent = body
	corner(row, 7)

	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(0, 110, 1, 0)
	label.Position = UDim2.new(0, 12, 0, 0)
	label.BackgroundTransparency = 1
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextColor3 = COLORS.dim
	label.Font = Enum.Font.Gotham
	label.TextSize = 12
	label.Text = labelText
	label.Parent = row

	local valueBox = Instance.new("Frame")
	valueBox.Size = UDim2.new(1, -188, 0, 20)
	valueBox.Position = UDim2.new(0, 122, 0.5, -10)
	valueBox.BackgroundColor3 = COLORS.bg
	valueBox.BorderSizePixel = 0
	valueBox.Parent = row
	corner(valueBox, 5)

	local value = Instance.new("TextLabel")
	value.Size = UDim2.new(1, -6, 1, 0)
	value.Position = UDim2.new(0, 3, 0, 0)
	value.BackgroundTransparency = 1
	value.TextColor3 = COLORS.text
	value.Font = Enum.Font.GothamMedium
	value.TextSize = 11
	value.Text = getValue()
	value.Parent = valueBox

	local function step(text, x, delta)
		local b = Instance.new("TextButton")
		b.Size = UDim2.fromOffset(26, 20)
		b.Position = UDim2.new(1, x, 0.5, -10)
		b.BackgroundColor3 = COLORS.bg
		b.BorderSizePixel = 0
		b.Text = text
		b.TextColor3 = COLORS.accent
		b.Font = Enum.Font.GothamBold
		b.TextSize = 15
		b.AutoButtonColor = false
		b.Parent = row
		corner(b, 5)
		b.MouseButton1Click:Connect(function()
			onStep(delta)
			value.Text = getValue()
		end)
	end
	step("−", -62, -1)
	step("+", -32, 1)
	return function() value.Text = getValue() end
end

local function makeButton(text, tone)
	local b = Instance.new("TextButton")
	b.Size = UDim2.new(1, -6, 0, 28)
	b.BackgroundColor3 = COLORS.panel
	b.BorderSizePixel = 0
	b.Text = text
	b.TextColor3 = tone or COLORS.accent
	b.Font = Enum.Font.GothamMedium
	b.TextSize = 12
	b.AutoButtonColor = false
	b.LayoutOrder = nextOrder()
	b.Parent = body
	corner(b, 7)
	return b
end

makeToggle("Auto Farm brainrots", "autoFarm", nil, COLORS.warn)
makeToggle("Clear mining blocks", "killBlocks", setBlockClearing)
makeToggle("Auto collect money", "autoCollect")
makeToggle("Buy Strength", "buyStrength")
makeToggle("Buy Carry", "buyCarry")
makeToggle("Buy Speed", "buySpeed")
makeToggle("Upgrade brainrots", "upgradeBrainrots")
makeToggle("Auto Rebirth", "autoRebirth", nil, COLORS.warn)
makeToggle("Replace weakest when full", "replaceWeak", nil, COLORS.warn)
local refreshMin = makeRow("Min score", function() return shortNumber(CONFIG.minScore) end, function(delta)
	local steps = { 0, 1e6, 1e7, 1e8, 1e9, 5e9, 1e10, 5e10 }
	local index = 1
	for i, v in ipairs(steps) do if CONFIG.minScore >= v then index = i end end
	CONFIG.minScore = steps[math.clamp(index + delta, 1, #steps)]
end)

local grabButton = makeButton("Fetch best brainrot now")
grabButton.MouseButton1Click:Connect(function() task.spawn(farmStep) end)

local baseButton = makeButton("Teleport to base")
baseButton.MouseButton1Click:Connect(function()
	pcall(function() Remotes.TeleportToBase:FireServer() end)
end)

local footer = Instance.new("Frame")
footer.Size = UDim2.new(1, -16, 0, 84)
footer.Position = UDim2.new(0, 8, 1, -92)
footer.BackgroundColor3 = COLORS.header
footer.BorderSizePixel = 0
footer.Parent = frame
corner(footer, 8)

local footerCredit = Instance.new("TextLabel")
footerCredit.Size = UDim2.fromOffset(120, 14)
footerCredit.Position = UDim2.new(1, -128, 1, -18)
footerCredit.BackgroundTransparency = 1
footerCredit.Text = "seltonmt"
footerCredit.TextXAlignment = Enum.TextXAlignment.Right
footerCredit.TextColor3 = COLORS.accent
footerCredit.Font = Enum.Font.GothamBold
footerCredit.TextSize = 10
footerCredit.TextTransparency = 0.25
footerCredit.Parent = footer

local status = Instance.new("TextLabel")
status.Size = UDim2.new(1, -18, 1, -12)
status.Position = UDim2.new(0, 9, 0, 6)
status.BackgroundTransparency = 1
status.TextXAlignment = Enum.TextXAlignment.Left
status.TextYAlignment = Enum.TextYAlignment.Top
status.TextColor3 = COLORS.dim
status.Font = Enum.Font.Code
status.TextSize = 11
status.Text = ""
status.Parent = footer

UserInputService.InputBegan:Connect(function(input, typing)
	if typing then return end
	if input.KeyCode == Enum.KeyCode.RightShift then frame.Visible = not frame.Visible end
end)

-- Loops -------------------------------------------------------------------------

local function loop(interval, key, fn)
	task.spawn(function()
		while _G.__DRILL == generation do
			if CONFIG[key] then pcall(fn) end
			task.wait(interval)
		end
	end)
end


task.spawn(function()
	while _G.__DRILL == generation do
		if CONFIG.autoCollect then pcall(collect) end
		task.wait(CONFIG.collectEvery)
	end
end)

task.spawn(function()
	while _G.__DRILL == generation do
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
		refreshMin()
		headline.Text = string.format("$%s   rb %d   trips %d%s",
			STATE.money, STATE.rebirths, STATE.trips,
			liveMoney and ("   exact " .. shortNumber(liveMoney)) or "")
		status.Text = string.format(
			"items %d   free slots %d   swaps %d\ncarrying %s\ntarget %s\npicked %d  placed %d\n%s\n%s",
			STATE.itemsSeen, STATE.freeSlots, STATE.swaps, STATE.collects, STATE.collects,
			STATE.carrying, STATE.target,
			STATE.picked, STATE.placed,
			STATE.phase, STATE.note
		)
		task.wait(0.5)
	end
	gui:Destroy()
end)

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
