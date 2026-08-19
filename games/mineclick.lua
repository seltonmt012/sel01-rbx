--!nocheck
-- mineclick.lua  --  "+1 Mine Per Click ⛏️"  (place 74193805629461, VERY LUCKY)
--
-- The loop: clicking makes Strength, Strength makes levels, levels allow
-- rebirths, rebirths unlock better training areas and multiply everything. Cash
-- comes from loot lying in the mine, and cash buys pickaxes, which is what makes
-- walls break fast enough to reach the deeper stages.
--
-- THIS GAME HAS AN ANTI-CHEAT and it is the first one in this repo that does.
-- `ReplicatedFirst.AnticheatClient` ("ZAC") is a pure **executor fingerprint
-- scan**: it walks a list of ~50 globals (writefile, readfile, getgenv, gethui,
-- decompile, hookfunction, hookmetamethod, getconnections, identifyexecutor …)
-- and the first one that exists fires `ZAC_Report:FireServer(reason, detail,
-- "HIGH")` plus a jumpscare. What it does NOT do, verified by reading the whole
-- 13.8K source: no walkspeed check, no position check, no teleport check, no
-- magnitude check - the words do not appear once. So the farming below is
-- invisible to it; only the executor itself is what it looks for, and it fires
-- at most once per session (`u2` latches). Nothing here pokes ZAC.
--
-- Everything below is measured against the server, and the oracle is the
-- Replica: `require(RS.Client.DataClient):GetReplica().Data` carries Cash,
-- Strength, Rebirths, WallsBroken, BackpackSize, ExtraWalkSpeed, Pickaxes,
-- StagesUnlocked and Auras as real server-written values.
--
--   * `Remotes.Server.Click:FireServer()` takes NO arguments and credits from
--     anywhere. The server caps the CALL RATE at ~8.5/s: one call per frame
--     gained 43 Strength in 5s, three calls per frame gained 42 in the same 5s.
--     One per Heartbeat is the whole budget - a published script for this game
--     fires four per frame, which buys exactly nothing.
--     What each call is worth is the equipped pickaxe's Strength times the area
--     multiplier: 8.5/s with the Wood Pickaxe (Strength 1) became 20.6M/s once
--     the Hacked Pickaxe (Strength 750,000) was equipped. So the pickaxe is not
--     only a mining stat, it IS the click rate - buy it before anything else.
--   * Training areas multiply that: spawn 8.4/s against 12/s inside Coal Ore,
--     which is the x1.5 from TrainingList, dead on. The ladder is Coal x1.5 at 0
--     rebirths up to Demonite x10 at 15. Azurite x100, Emerald x25 and Amethyst
--     x15 carry a GamepassId and are never touched.
--   * `HitWall:FireServer(stageId, wallIndex)` works from ANY distance - stage 1
--     walls 1-3 broke while the character stood in the training area. But the
--     client does it by itself and better: `StageClient` puts a ZonePlus zone on
--     `workspace.Stages["Stage n"].Hitbox`, and entering it sets CurrentStageId,
--     resolves the next unbroken wall and runs its own punching loop. Standing
--     in the hitbox broke all three walls of stage 1 in one 10s window
--     (BreakWall(1,1), (1,2), (1,3)), so the script only has to stand there.
--   * **The loot cycle has three gates and missing any one of them looks exactly
--     like a broken script.** The loot itself lies at
--     `Stages["Stage n"].Spawnpoints.<GUID>` with `ItemId` / `StageId` /
--     `IsTaken` attributes:
--       1. It is picked up with an E press, not a touch. The ProximityPrompt is
--          a DESCENDANT of the spawn part (under the item model) and only exists
--          once the client has built it, so it has to be searched recursively
--          and waited for.
--       2. The stage has to be FINISHED. An unfinished one answers every pickup
--          with "Complete Stage 12 First!" - and reaching a stage is not
--          finishing it: StagesUnlocked read 1..12 while stages 3, 10 and 12
--          still refused their loot. Hence stages are cleared lowest-first.
--       3. The backpack has to have room. At 5/5 every prompt answers "Backpack
--          is full! (Goto Surface)" and pays nothing - the state that had this
--          script teleporting onto loot all day for zero cash.
--     The payout is not per pickup either: `GotoSurface:FireServer()` empties the
--     bag (Storage 5 -> 0) and `SellAllLoot:FireServer()` pays for the load.
--     Measured: one full bag paid 93,840, and a 22s cycle of break -> collect ->
--     surface -> sell paid 399,750.
--   * `player.data.Storage` is how full the bag is, `Data.BackpackSize` the cap.
--     `Data.Inventory` stays empty the whole time and is NOT the inventory -
--     watching it is what hid the backpack gate for so long.
--   * The loot is a RACE. 223 spawn points exist and with 14 players on the
--     server only 0-9 are free at any moment - they refill on a cycle, they are
--     not created fresh (zero new instances in 20s). A teleporting bot wins that
--     race, which is the whole reason this script is worth running.
--   * Formulas out of the helpers, not guessed: level curve starts at 45 with
--     growth 1.095, rebirth needs level `25 + rebirths * 25`, cash multiplier is
--     `1 + rebirths * 0.2`, strength multiplier `1 + rebirths * 0.5`, backpack
--     costs `200000 * 2.85^(size-3)` and walkspeed `10000 * 1.4^extra`.
--     Verified against the balance: backpack 3 -> 4 charged exactly 200,000 and
--     walkspeed 0 -> 1 exactly 10,000.
--   * `PurchasePickaxe:FireServer(name, "Cash")` then `EquipPickaxe(name)`:
--     bought the Hacked Pickaxe (750,000 strength) for 80,000,000 and it landed
--     in Data.Pickaxes and got equipped. The `"Robux"` second argument is the
--     other way to pay and is never used here.
--   * `Rebirth:FireServer("Rebirth")` is refused below the level gate - fired at
--     level 11 against a required 25 it changed nothing at all, no error.
--
-- Robux, never touched: every `ProductId` / `GamepassId` entry in PickaxeList,
-- AurasList and TrainingList, the `"Robux"` argument on every purchase remote,
-- `Rebirth:FireServer("Skip")`, SkipStage and the whole Remotes.Admin folder.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local plr = Players.LocalPlayer
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local Server = Remotes:WaitForChild("Server")

local Click        = Server:WaitForChild("Click")
local HitWall      = Server:WaitForChild("HitWall")
local SellAllLoot  = Server:WaitForChild("SellAllLoot")
local PurchasePick = Server:WaitForChild("PurchasePickaxe")
local EquipPick    = Server:WaitForChild("EquipPickaxe")
local RebirthRE    = Server:WaitForChild("Rebirth")
local UpgradeSlot  = Server:WaitForChild("UpgradeSlot")
local UpgradeWalk  = Server:WaitForChild("UpgradeWalkspeed")
local PurchaseAura = Server:WaitForChild("PurchaseAura")
local EquipAura    = Server:WaitForChild("EquipAura")
local GroupReward  = Server:WaitForChild("GroupReward")
local TeleportStage= Server:WaitForChild("TeleportToStage")
local GotoSurface  = Server:WaitForChild("GotoSurface")

local ClientRemotes    = Remotes:WaitForChild("Client")
local UpdateWallHealth = ClientRemotes:WaitForChild("UpdateWallHealth")

local Client       = ReplicatedStorage:WaitForChild("Client")
local DataClient   = require(Client:WaitForChild("DataClient"))
local StageClient  = require(Client:WaitForChild("StageClient"))

local Databases    = ReplicatedStorage:WaitForChild("Databases")
local StagesList   = require(Databases:WaitForChild("StagesList"))
local PickaxeList  = require(Databases:WaitForChild("PickaxeList"))
local TrainingList = require(Databases:WaitForChild("TrainingList"))
local AurasList    = require(Databases:WaitForChild("AurasList"))
local ItemsList    = require(Databases:WaitForChild("ItemsList"))

local Helpers      = ReplicatedStorage:WaitForChild("Helpers")
local LevelsHelper = require(Helpers:WaitForChild("LevelsHelper"))
local UpgradesHelper = require(Helpers:WaitForChild("UpgradesHelper"))

--------------------------------------------------------------------------------
-- config / state
--------------------------------------------------------------------------------

local CONFIG = {
	auto = false,
	click = true,            -- one Click per Heartbeat, the server's whole budget
	autoLoot = true,         -- the cash engine: race the other players to the loot
	autoSell = true,         -- GotoSurface + SellAllLoot whenever the bag is full
	autoMine = true,         -- stand in the stage hitbox, the client breaks the walls
	autoTrain = true,        -- park in the best free training area when idle
	autoPickaxe = true,
	autoAura = true,
	autoUpgrade = true,      -- backpack + walkspeed
	autoRebirth = true,
	lootRange = 0,           -- 0 = the whole map, otherwise studs from the character
	pickaxeReserve = true,   -- keep the cash the next pickaxe needs
	-- Settle is a race setting, not a safety setting. Loot is contested by every
	-- player on the server: measured 17 grabs worth 1,878 cash at 0.35s, and
	-- nothing at all at 1.2s, because somebody else always got there first.
	settle = 0.35,
	stageDwell = 6,          -- seconds spent breaking one stage before re-checking
	lootWait = 0.6,          -- seconds to wait for a drop before calling a stage empty
}

local STATE = {
	note = "idle",
	mode = "idle",           -- loot / mine / train
	target = nil,            -- Vector3 the pin writes
	targetName = "-",
	cash = 0, strength = 0, rebirths = 0, level = 0, walls = 0,
	needLevel = 0,
	cashRate = 0, strengthRate = 0,
	lastCash = 0, lastStrength = 0, lastAt = 0,
	picked = 0,              -- loot grabbed this run
	stage = 1,
	uiOwner = nil,
	blocked = nil,
}

_G.__MINECLICK = (_G.__MINECLICK or 0) + 1
local GEN = _G.__MINECLICK

--------------------------------------------------------------------------------
-- reading the server's view
--------------------------------------------------------------------------------

local replica = DataClient:GetReplica()

local function data()
	if not replica or not replica.Data then replica = DataClient:GetReplica() end
	return replica and replica.Data or {}
end

local function short(n)
	if type(n) ~= "number" then return "?" end
	local units = { "", "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", "Dc" }
	local i = 1
	while n >= 1000 and i < #units do n = n / 1000 i = i + 1 end
	if i == 1 then return string.format("%d", n) end
	return string.format("%.2f%s", n, units[i])
end

local function root()
	local c = plr.Character
	return c and c:FindFirstChild("HumanoidRootPart")
end

local function withUI(name, fn)
	if STATE.uiOwner then return false end
	STATE.uiOwner = name
	local ok, err = pcall(fn)
	STATE.uiOwner = nil
	if not ok then STATE.note = name .. " failed: " .. tostring(err) end
	return ok
end

--------------------------------------------------------------------------------
-- the pin
--------------------------------------------------------------------------------

-- Click has no position check at all, so it is fired every frame no matter what
-- the body is doing - during a loot run, inside the mine, anywhere. Only the
-- training multiplier depends on where the character stands.
local pinConn
local function startPin()
	if pinConn then pinConn:Disconnect() end
	pinConn = RunService.Heartbeat:Connect(function()
		if GEN ~= _G.__MINECLICK then pinConn:Disconnect() return end
		if not CONFIG.auto then return end
		if CONFIG.click then Click:FireServer() end
		local hrp = root()
		if hrp and STATE.target then hrp.CFrame = CFrame.new(STATE.target) end
	end)
end

--------------------------------------------------------------------------------
-- loot - the cash engine
--------------------------------------------------------------------------------

-- Loot parts sit under Stages["Stage n"].Spawnpoints as GUID-named parts with
-- ItemId / StageId / IsTaken attributes. IsTaken == false means it is up for
-- grabs, and touching it pays out immediately - there is no inventory step and
-- no sell step, which is the single most surprising thing about this game.
-- Loot in a stage the player has not reached cannot be taken - the server just
-- ignores the touch, and the game says so in its own words ("finish stage X
-- first"). StagesUnlocked is that record, and a REBIRTH WIPES IT: after six
-- rebirths it came back empty, so the whole map was off limits again while the
-- first version of this script still ran across it grabbing at nothing.
local function maxUnlockedStage()
	local best = 1
	for key, value in pairs(data().StagesUnlocked or {}) do
		local num = tonumber(key) or tonumber(value)
		if num and num > best then best = num end
	end
	return best
end

-- A stage counts as DONE when it has no unbroken wall left, and that is what the
-- game means by "Complete Stage 12 First!" - the message every pickup inside an
-- unfinished stage answers with. Reaching a stage is not finishing it, so
-- StagesUnlocked alone is the wrong test: the record read 1..12 while stages 3,
-- 10 and 12 were still refusing their loot. Defined here because freeLoot needs
-- it and a local is invisible above its definition.
local function stageDone(stageNum)
	local ok, wall = pcall(StageClient.GetNextWall, StageClient, stageNum)
	return ok and wall == nil
end

local function freeLoot()
	local out = {}
	local hrp = root()
	local from = hrp and hrp.Position
	local stages = Workspace:FindFirstChild("Stages")
	if not stages then return out end
	local allowed = maxUnlockedStage()
	for _, stage in ipairs(stages:GetChildren()) do
		local num = tonumber(stage.Name:match("%d+")) or 1
		-- reached AND finished, or the server answers "Complete Stage n First!"
		local spawns = (num <= allowed and stageDone(num)) and stage:FindFirstChild("Spawnpoints") or nil
		if spawns then
			for _, part in ipairs(spawns:GetChildren()) do
				if part:IsA("BasePart") and part:GetAttribute("IsTaken") == false then
					local dist = from and (part.Position - from).Magnitude or 0
					if CONFIG.lootRange <= 0 or dist <= CONFIG.lootRange then
								out[#out + 1] = { part = part, dist = dist, value = (itemValue(part)) }
					end
				end
			end
		end
	end
	table.sort(out, function(a, b)
		if a.value ~= b.value then return a.value > b.value end
		return a.dist < b.dist
	end)
	return out
end

-- The backpack is the whole reason a pickup can silently fail. `player.data
-- .Storage` is how full it is and `Data.BackpackSize` is the cap; at 5/5 every
-- prompt answers "Backpack is full! (Goto Surface)" and pays nothing, which is
-- exactly what a bot looks like when it teleports onto loot all day and earns
-- zero. Verified: GotoSurface emptied it 5 -> 0 and SellAllLoot then paid 93,840.
local function storage()
	local folder = plr:FindFirstChild("data")
	local value = folder and folder:FindFirstChild("Storage")
	return value and value.Value or 0
end

local function backpackFull()
	return storage() >= (data().BackpackSize or 3)
end

local function sellRun()
	if storage() <= 0 then return false end
	STATE.mode = "sell"
	STATE.targetName = "surface (selling " .. storage() .. ")"
	local before = data().Cash or 0
	GotoSurface:FireServer()
	task.wait(1.2)
	SellAllLoot:FireServer()
	task.wait(1.2)
	local gained = (data().Cash or 0) - before
	if gained > 0 then
		STATE.sold = (STATE.sold or 0) + gained
		STATE.note = "sold for " .. short(gained)
	end
	return true
end

-- Every drop carries its own price tag on the billboard ("$140K"), and that is
-- the number to rank on: the same ItemId shows up at different rarities and the
-- database Revenue is only the base. With five backpack slots the choice between
-- a 140K Pirate Hat and a 70K Treasure Chest is the entire difference between a
-- good load and a wasted one.
local SUFFIX = { K = 1e3, M = 1e6, B = 1e9, T = 1e12, Qa = 1e15, Qi = 1e18 }

local function parseMoney(text)
	if type(text) ~= "string" then return nil end
	local num, suffix = text:match("%$?%s*([%d%.]+)%s*(%a*)")
	num = tonumber(num)
	if not num then return nil end
	if suffix and suffix ~= "" then
		local mult = SUFFIX[suffix] or SUFFIX[suffix:sub(1, 1):upper() .. (suffix:sub(2, 2) or "")]
		if not mult then return nil end   -- never guess a suffix, see the Q trap
		num = num * mult
	end
	return num
end

local function itemValue(part)
	local id = part:GetAttribute("ItemId")
	for _, label in ipairs(part:GetDescendants()) do
		if label:IsA("TextLabel") and label.Name == "Revenue" then
			local value = parseMoney(label.Text)
			if value then return value, id end
		end
	end
	local entry = id and ItemsList[id]
	return (entry and entry.Revenue) or 0, id
end

-- Touch is what pays. A ProximityPrompt exists on some of them but only once the
-- client has built it, so the touch path is the reliable one and the prompt is
-- fired as a second chance.
-- The body has to ARRIVE before the touch counts. Warping in and firing in the
-- same breath is what made the first version look busy and earn nothing: it hit
-- the part while the server still had the character somewhere else. So it
-- settles first, then touches repeatedly, and the payout is confirmed against
-- the cash balance rather than against the call returning.
local function grab(part)
	local hrp = root()
	if not hrp or not part.Parent then return false end
	STATE.target = part.Position + Vector3.new(0, 2, 0)
	local _, id = itemValue(part)
	STATE.targetName = "loot " .. tostring(id)

	-- Confirm against the BAG, not the balance: a pickup fills the backpack and
	-- the cash only arrives later at the surface, so watching Cash here counted
	-- every successful grab as a failure.
	local before = storage()
	task.wait(CONFIG.settle)

	-- The pickup is an E press, not a touch. Two things made the first versions
	-- teleport onto loot and come back with nothing: the ProximityPrompt is a
	-- DESCENDANT (it hangs under the item model, not on the spawn part), and it
	-- does not exist until the client has built it for a nearby item - so the
	-- prompt has to be waited for, then held for its HoldDuration.
	local prompt
	local deadline = os.clock() + 1.5
	repeat
		prompt = part:FindFirstChildWhichIsA("ProximityPrompt", true)
		if prompt then break end
		task.wait(0.1)
	until os.clock() > deadline

	for _ = 1, 3 do
		if not part.Parent then break end
		if prompt then
			pcall(fireproximityprompt, prompt, prompt.HoldDuration or 0)
		end
		pcall(function()
			firetouchinterest(hrp, part, 0)
			firetouchinterest(hrp, part, 1)
		end)
		task.wait(0.25)
		if storage() > before then
			STATE.picked = STATE.picked + 1
			return true
		end
		prompt = prompt or part:FindFirstChildWhichIsA("ProximityPrompt", true)
	end
	if not prompt then STATE.blocked = "no pickup prompt on " .. tostring(id) end
	return false
end

--------------------------------------------------------------------------------
-- mining
--------------------------------------------------------------------------------

-- The deepest stage whose hitbox exists. Standing in it is the entire job: the
-- game's own StageClient zone handler picks the next unbroken wall and swings.
-- The stage to WORK ON is one deeper than the deepest one unlocked, because
-- breaking the walls in a stage is what unlocks it - measured: standing in the
-- stage 2 hitbox with StagesUnlocked = {1} broke three walls and the record came
-- back {1, 2}. TeleportToStage itself neither charges nor unlocks anything, so
-- the body simply parks in the next hitbox. Only when that stage is out of walls
-- does the target move on.
-- Work the LOWEST unfinished stage, not the deepest reachable one. Going deep
-- first is what left a trail of half-cleared stages whose loot could never be
-- taken, while the body hammered a wall far below that its pickaxe cannot chew.
local function workStage()
	local stages = Workspace:FindFirstChild("Stages")
	if not stages then return nil end
	local limit = math.min(maxUnlockedStage() + 1, 30)
	for num = 1, limit do
		local folder = stages:FindFirstChild("Stage " .. num)
		local hitbox = folder and folder:FindFirstChild("Hitbox")
		if hitbox and not stageDone(num) then return hitbox, num end
	end
	local folder = stages:FindFirstChild("Stage " .. limit)
	local hitbox = folder and folder:FindFirstChild("Hitbox")
	return hitbox, limit
end

local function wallsLeft(stageNum)
	local ok, wall = pcall(StageClient.GetNextWall, StageClient, stageNum)
	return ok and wall or nil
end

--------------------------------------------------------------------------------
-- training
--------------------------------------------------------------------------------

-- Highest multiplier the rebirth count allows, gamepass areas excluded. Their
-- folders exist in the map either way, so the GamepassId is the only honest
-- filter - a x100 area we cannot use would otherwise win every comparison.
local function bestTrainingArea()
	local areas = Workspace:FindFirstChild("Map")
	areas = areas and areas:FindFirstChild("Training Areas")
	if not areas then return nil end
	local best, bestMult, bestName = nil, -1, nil
	for id, info in pairs(TrainingList) do
		if not info.GamepassId and (data().Rebirths or 0) >= (info.MinimumRebirths or 0) then
			local folder = areas:FindFirstChild(info.Folder or id)
			local mult = tonumber(info.Multiplier) or 0
			if folder and mult > bestMult then
				local ok, pivot = pcall(function() return folder:GetPivot().Position end)
				if ok then best, bestMult, bestName = pivot + Vector3.new(0, 5, 0), mult, id end
			end
		end
	end
	return best, bestMult, bestName
end

--------------------------------------------------------------------------------
-- spending
--------------------------------------------------------------------------------

-- An owned list here can be either an array of names OR a set keyed by name -
-- Pickaxes came back as an array and Auras as a set, and reading only the values
-- made the aura routine buy Flame x1.2 while Green Flame x1.4 was already owned.
-- Take both sides of every pair.
local function ownedSet(list)
	local owned = {}
	for key, value in pairs(list or {}) do
		if type(key) == "string" then owned[key] = true end
		if type(value) == "string" then owned[value] = true end
	end
	return owned
end

local function nextPickaxeCost()
	local d = data()
	local owned = ownedSet(d.Pickaxes)
	local bestOwned = 0
	for name in pairs(owned) do
		local e = PickaxeList[name]
		if e then bestOwned = math.max(bestOwned, tonumber(e.Strength) or 0) end
	end
	local cheapest = math.huge
	for name, e in pairs(PickaxeList) do
		local price, str = tonumber(e.Price) or math.huge, tonumber(e.Strength) or 0
		if not owned[name] and str > bestOwned and price < cheapest then cheapest = price end
	end
	return cheapest == math.huge and 0 or cheapest
end

local function canSpend(cost)
	local cash = data().Cash or 0
	if cost > cash then return false end
	if not CONFIG.pickaxeReserve then return true end
	if cost <= cash * 0.01 then return true end
	return cash - cost >= nextPickaxeCost()
end

-- Rank on Strength, never on price: the list is not ordered and a cheap late
-- entry would otherwise beat an expensive better one.
local function buyPickaxe()
	if not CONFIG.autoPickaxe then return end
	local d = data()
	local owned = ownedSet(d.Pickaxes)
	local equipped = PickaxeList[d.EquippedPickaxeId or ""]
	local equippedStr = equipped and tonumber(equipped.Strength) or 0

	local pick, pickStr = nil, equippedStr
	for name, e in pairs(PickaxeList) do
		local price, str = tonumber(e.Price) or math.huge, tonumber(e.Strength) or 0
		if str > pickStr and (owned[name] or price <= (d.Cash or 0)) then pick, pickStr = name, str end
	end
	if not pick then return end
	if not owned[pick] then
		PurchasePick:FireServer(pick, "Cash")
		task.wait(0.8)
		STATE.note = "pickaxe " .. pick .. " (" .. short(pickStr) .. " str) for " ..
			short(tonumber(PickaxeList[pick].Price) or 0)
	end
	if data().EquippedPickaxeId ~= pick then
		EquipPick:FireServer(pick)
	end
end

local function buyAura()
	if not CONFIG.autoAura then return end
	local d = data()
	local owned = ownedSet(d.Auras)
	local pick, pickMult = nil, 0
	for name, e in pairs(AurasList) do
		local mult = tonumber(e.Multiplier) or 0
		if not owned[name] and mult > pickMult and canSpend(tonumber(e.Price) or math.huge) then
			pick, pickMult = name, mult
		end
	end
	if pick then
		PurchaseAura:FireServer(pick)
		STATE.note = "aura " .. pick .. " x" .. pickMult .. " for " .. short(tonumber(AurasList[pick].Price) or 0)
		task.wait(0.8)
	end
	-- wear the best one owned, which is not always the one just bought
	local wear, wearMult = nil, 0
	for name in pairs(ownedSet(data().Auras)) do
		local e = AurasList[name]
		if e and (tonumber(e.Multiplier) or 0) > wearMult then wear, wearMult = name, tonumber(e.Multiplier) end
	end
	if wear then EquipAura:FireServer(wear) end
end

-- The backpack is bought with UpgradeSlot("Cash") and runs 3 -> 20 slots at
-- `200000 * 2.85^(size-3)` (verified: 3 -> 4 charged exactly 200,000). Every
-- extra slot is one more piece per surface run, so it is worth more than an aura
-- and is allowed past the pickaxe reserve while it is still cheap.
local function buyUpgrades()
	if not CONFIG.autoUpgrade then return end
	local d = data()
	local size = d.BackpackSize or 3
	if size < (UpgradesHelper.MaxBackpackSize or 20) then
		local cost = UpgradesHelper:GetBackpackUpgradeCost(size)
		if canSpend(cost) or cost <= (d.Cash or 0) * 0.25 then
			UpgradeSlot:FireServer("Cash")
			STATE.note = "backpack " .. size .. " -> " .. (size + 1) .. " for " .. short(cost)
			task.wait(0.5)
		end
	end
	local extra = data().ExtraWalkSpeed or 0
	if extra < (UpgradesHelper.MaxWalkspeed or 50) then
		local cost = UpgradesHelper:GetWalkspeedUpgradeCost(extra)
		if canSpend(cost) then
			UpgradeWalk:FireServer("Cash")
			task.wait(0.5)
		end
	end
end

-- Level 25 for the first rebirth, then 25 more each time. Refused below that
-- with no error at all, so the gate is checked here rather than fired blind.
local function tryRebirth()
	if not CONFIG.autoRebirth then return end
	local d = data()
	local level = LevelsHelper:GetLevel(d.Strength or 0)
	local need = LevelsHelper:GetRequiredRebirthLevel(d.Rebirths or 0)
	if level < need then return end
	RebirthRE:FireServer("Rebirth")
	task.wait(1)
	if (data().Rebirths or 0) > (d.Rebirths or 0) then
		STATE.note = "rebirth " .. data().Rebirths .. " at level " .. need ..
			"  cash x" .. LevelsHelper:GetCashMultiplier(data().Rebirths) ..
			"  str x" .. LevelsHelper:GetStrengthMultiplier(data().Rebirths)
	end
end

local function claimFree()
	pcall(function() GroupReward:FireServer() end)
	pcall(function() SellAllLoot:FireServer() end)
end

local function unstuck()
	CONFIG.auto = false
	STATE.target = nil
	local c = plr.Character
	local hrp = c and c:FindFirstChild("HumanoidRootPart")
	local hum = c and c:FindFirstChildOfClass("Humanoid")
	if hrp then
		hrp.Anchored = false
		hrp.AssemblyLinearVelocity = Vector3.zero
	end
	if hum then
		hum.PlatformStand = false
		hum:ChangeState(Enum.HumanoidStateType.GettingUp)
	end
	STATE.note = "unstuck, auto off"
end

--------------------------------------------------------------------------------
-- the brain - three jobs, one body
--------------------------------------------------------------------------------

-- Loot first because it is the only contested resource on the server: 223 spawn
-- points, 0-9 free at a time, and whoever arrives first is paid. Mining is
-- uncontested and waits. Training is what happens when there is nothing to grab.
-- Everything that is free inside ONE stage, nearest first. Loot appears in the
-- stage you are breaking, so this is the list that matters after a wall falls -
-- not whatever is lying around the rest of the map, which belongs to whoever is
-- standing next to it.
local function stageLoot(stageNum)
	local out = {}
	local folder = Workspace.Stages:FindFirstChild("Stage " .. stageNum)
	local spawns = folder and folder:FindFirstChild("Spawnpoints")
	if not spawns then return out end
	local hrp = root()
	local from = hrp and hrp.Position
	for _, part in ipairs(spawns:GetChildren()) do
		if part:IsA("BasePart") and part:GetAttribute("IsTaken") == false then
			out[#out + 1] = {
				part = part,
				dist = from and (part.Position - from).Magnitude or 0,
				value = (itemValue(part)),
			}
		end
	end
	-- richest first, nearest as the tiebreak
	table.sort(out, function(a, b)
		if a.value ~= b.value then return a.value > b.value end
		return a.dist < b.dist
	end)
	return out
end

-- Clear a stage's loot until it stays empty for a full sweep, ALWAYS taking the
-- richest piece still lying there. The list is re-read after every grab because
-- the other players are taking things at the same time and because a fresh drop
-- can outclass whatever was planned - with five slots, order is the difference
-- between a 140K load and a 700 one.
local function collectStage(stageNum)
	local empty = 0
	while empty < 2 and CONFIG.auto and GEN == _G.__MINECLICK do
		if backpackFull() then
			if CONFIG.autoSell then sellRun() end
			return
		end
		local loot = stageLoot(stageNum)
		if #loot == 0 then
			empty = empty + 1
			task.wait(CONFIG.lootWait)
		else
			empty = 0
			STATE.mode = "loot"
			local best = loot[1]
			STATE.targetName = "stage " .. stageNum .. " best: " ..
				tostring(best.part:GetAttribute("ItemId")) .. " " .. short(best.value or 0)
			if best.part.Parent and best.part:GetAttribute("IsTaken") == false then
				grab(best.part)
			end
		end
	end
end

local function think()
	-- Empty the bag first. A full backpack makes every single pickup fail with a
	-- red "Backpack is full!" and no cash, so nothing else is worth doing.
	if CONFIG.autoSell and backpackFull() then
		sellRun()
		return
	end

	if CONFIG.autoLoot then
		local loot = freeLoot()
		if #loot > 0 then
			STATE.mode = "loot"
			for i = 1, math.min(#loot, 6) do
				if not CONFIG.auto or GEN ~= _G.__MINECLICK then return end
				local entry = loot[i]
				if entry.part.Parent and entry.part:GetAttribute("IsTaken") == false then
					grab(entry.part)
				end
			end
			return
		end
	end

	-- Nothing free right now. That is the NORMAL state, not a reason to run off:
	-- loot appears while you are standing in the stage, so the body parks in the
	-- deepest hitbox it is allowed into and waits there. Breaking walls happens
	-- in the same spot because the game's own zone handler does it, so waiting
	-- and mining are the same action.
	local hitbox, stageNum = workStage()
	if CONFIG.autoMine and hitbox then
		STATE.stage = stageNum
		STATE.target = hitbox.Position

		-- Park in the hitbox AND fire HitWall directly: the client's own zone
		-- loop only swings while it has a wall resolved, and it stops as soon as
		-- the stage is spent, while the remote takes the wall index straight.
		--
		-- Progress is measured as DAMAGE, not as broken walls. Deep walls have
		-- more health than one dwell window can chew through, and counting only
		-- breaks made the script declare a perfectly good stage dead.
		local before = data().WallsBroken or 0
		local damaged = false
		local hpConn = UpdateWallHealth.OnClientEvent:Connect(function() damaged = true end)
		local deadline = os.clock() + CONFIG.stageDwell
		local finished = false
		while os.clock() < deadline and CONFIG.auto and GEN == _G.__MINECLICK do
			local wall = wallsLeft(stageNum)
			if not wall then
				-- Stage is done THIS instant. Sitting out the rest of the dwell
				-- window here is what made it look like the script kept digging
				-- a finished stage instead of moving on.
				finished = true
				break
			end
			HitWall:FireServer(stageNum, wall)
			task.wait(0.12)
		end
		hpConn:Disconnect()

		if finished then
			STATE.mode = "mine"
			STATE.targetName = "stage " .. stageNum .. " cleared"
			STATE.blocked = nil
			if CONFIG.autoLoot then collectStage(stageNum) end
			return
		end
		local gained = (data().WallsBroken or 0) - before
		if damaged and gained <= 0 then
			STATE.mode = "mine"
			STATE.targetName = "stage " .. stageNum .. " (chewing, wall not down yet)"
			STATE.blocked = nil
			return
		end

		if gained > 0 then
			STATE.mode = "mine"
			STATE.targetName = "stage " .. stageNum .. " (+" .. gained .. " walls)"
			STATE.blocked = nil
			-- The drops belong to the stage that was just broken, so empty it
			-- before moving on. Walking away from them was the whole bug.
			if CONFIG.autoLoot then collectStage(stageNum) end
			return
		end

		-- Nothing moved. That is either a spent stage or a server that will not
		-- take this stage yet, and hammering it forever is how a farm looks busy
		-- while earning zero - so say it and go train instead.
		STATE.mode = "wait"
		STATE.targetName = "stage " .. stageNum .. " took no hits"
		STATE.blocked = "stage " .. stageNum .. " refuses hits - walls spent for this server"
	end

	if CONFIG.autoTrain then
		local pos, mult, name = bestTrainingArea()
		if pos then
			STATE.mode = "train"
			STATE.target = pos
			STATE.targetName = (name or "?") .. " x" .. (mult or 1)
			task.wait(1)
			return
		end
	end

	STATE.mode = "idle"
	task.wait(1)
end

--------------------------------------------------------------------------------
-- loops
--------------------------------------------------------------------------------

local function loop(interval, key, fn)
	task.spawn(function()
		while GEN == _G.__MINECLICK do
			if CONFIG.auto and (key == nil or CONFIG[key]) then
				local ok, err = pcall(fn)
				if not ok then STATE.note = tostring(err) end
			end
			task.wait(interval)
		end
	end)
end

-- the brain runs as fast as it can; the loot race is decided in fractions
task.spawn(function()
	while GEN == _G.__MINECLICK do
		if CONFIG.auto then
			local ok, err = pcall(think)
			if not ok then STATE.note = tostring(err) task.wait(1) end
		else
			task.wait(0.5)
		end
		task.wait(0.05)
	end
end)

-- numbers and rebirth
loop(1, nil, function()
	local d = data()
	STATE.cash = d.Cash or 0
	STATE.strength = d.Strength or 0
	STATE.rebirths = d.Rebirths or 0
	STATE.walls = d.WallsBroken or 0
	STATE.level = LevelsHelper:GetLevel(STATE.strength)
	STATE.needLevel = LevelsHelper:GetRequiredRebirthLevel(STATE.rebirths)

	local now = os.clock()
	if STATE.lastAt > 0 and now > STATE.lastAt then
		local dt = now - STATE.lastAt
		local cr = (STATE.cash - STATE.lastCash) / dt
		local sr = (STATE.strength - STATE.lastStrength) / dt
		if cr > 0 then STATE.cashRate = STATE.cashRate > 0 and (STATE.cashRate * 0.6 + cr * 0.4) or cr end
		if sr > 0 then STATE.strengthRate = STATE.strengthRate > 0 and (STATE.strengthRate * 0.6 + sr * 0.4) or sr end
	end
	STATE.lastCash, STATE.lastStrength, STATE.lastAt = STATE.cash, STATE.strength, now

	tryRebirth()
end)

-- spending
loop(10, nil, function()
	withUI("spend", function()
		buyPickaxe()
		buyUpgrades()
		buyAura()
	end)
end)

loop(120, nil, claimFree)

-- Watch our own income. A farm that grabs, sells and still shows no cash after a
-- full minute is broken in a way that looks busy, which is exactly how the
-- backpack gate hid for so long - so it says so instead of pretending.
loop(60, nil, function()
	local now = data().Cash or 0
	local mark = STATE.incomeMark
	if mark then
		local gained = now - mark
		STATE.incomePerMin = gained
		if gained <= 0 then
			STATE.blocked = "no cash in 60s - bag " .. storage() .. "/" ..
				tostring(data().BackpackSize) .. ", stage " .. tostring(STATE.stage)
		elseif STATE.blocked and STATE.blocked:find("no cash") then
			STATE.blocked = nil
		end
	end
	STATE.incomeMark = now
end)

startPin()

--------------------------------------------------------------------------------
-- panel
--------------------------------------------------------------------------------

local UI = (_G.__SEL and _G.__SEL.ui) or loadstring(readfile("ui-template.lua"))()

if _G.__MINECLICK_WIN then pcall(function() _G.__MINECLICK_WIN:Destroy() end) end

local win = UI.Window({
	title = "MINE", accentTitle = "CLICK", subtitle = "seltonmt",
	badge = "⛏", width = 920, height = 580,
})
_G.__MINECLICK_WIN = win

local farm = win:Page("FARM", UI.icon.bolt)

local main = farm:Card("LOOP", 1)
main:Toggle("AUTO", CONFIG.auto, function(v)
	CONFIG.auto = v
	STATE.note = v and "running" or "stopped"
	if not v then STATE.target = nil end
end, "loot first, then mining, then training", UI.theme.good)
main:Toggle("Auto click", CONFIG.click, function(v) CONFIG.click = v end,
	"one Click per frame - that is the server's whole budget")
main:Toggle("Auto loot", CONFIG.autoLoot, function(v) CONFIG.autoLoot = v end,
	"grabs free spawn points, pays cash on touch")
main:Toggle("Auto sell", CONFIG.autoSell, function(v) CONFIG.autoSell = v end,
	"full bag = every pickup fails, so it surfaces and sells")
main:Toggle("Auto mine", CONFIG.autoMine, function(v) CONFIG.autoMine = v end,
	"stands in the deepest stage hitbox, the game breaks the walls")
main:Toggle("Auto train", CONFIG.autoTrain, function(v) CONFIG.autoTrain = v end,
	"best free area: Coal x1.5 up to Demonite x10")
main:Stepper("Settle time", function() return CONFIG.settle .. "s" end,
	function(dir) CONFIG.settle = math.clamp(CONFIG.settle + dir * 0.2, 0.2, 3) end,
	"wait after warping before touching - too short and the touch is ignored")
main:Stepper("Stage dwell", function() return CONFIG.stageDwell .. "s" end,
	function(dir) CONFIG.stageDwell = math.clamp(CONFIG.stageDwell + dir, 1, 20) end,
	"loot appears while you stand in the stage, so it waits there")
main:Stepper("Loot range", function()
	return CONFIG.lootRange == 0 and "whole map" or (CONFIG.lootRange .. " studs")
end, function(dir)
	CONFIG.lootRange = math.clamp(CONFIG.lootRange + dir * 50, 0, 2000)
end, "0 hunts the whole mine, which is what wins the race")

local spend = farm:Card("SPENDING", 2)
spend:Toggle("Auto pickaxe", CONFIG.autoPickaxe, function(v) CONFIG.autoPickaxe = v end,
	"best Strength the cash allows, paid in cash only", UI.theme.warn)
spend:Toggle("Auto aura", CONFIG.autoAura, function(v) CONFIG.autoAura = v end,
	"Flame x1.2 @100K up to Electric x4 @25B", UI.theme.warn)
spend:Toggle("Auto upgrades", CONFIG.autoUpgrade, function(v) CONFIG.autoUpgrade = v end,
	"backpack 200K x2.85 per step, walkspeed 10K x1.4", UI.theme.warn)
spend:Toggle("Auto rebirth", CONFIG.autoRebirth, function(v) CONFIG.autoRebirth = v end,
	"level 25 + 25 per rebirth, cash x1.2 and strength x1.5 each", UI.theme.warn)
spend:Toggle("Keep pickaxe reserve", CONFIG.pickaxeReserve, function(v) CONFIG.pickaxeReserve = v end,
	"nothing else spends the cash the next pickaxe needs")

local extra = farm:Card("EXTRAS", 1)
extra:Button("Unstuck", unstuck, UI.theme.bad)
extra:Label("no Robux path: every ProductId and GamepassId is filtered")
extra:Label("anticheat only scans for executor globals, not movement")

local out = farm:Card("STATUS", 0):Readout(12, function(text)
	if text:find("blocked") then return UI.theme.bad end
	if text:find("^AUTO") then return UI.theme.good end
	return nil
end)

task.spawn(function()
	while GEN == _G.__MINECLICK do
		local d = data()
		local lines = {
			(CONFIG.auto and "AUTO ON" or "AUTO OFF") .. "   " .. STATE.mode,
			"  cash   " .. short(STATE.cash) .. "   +" .. short(STATE.cashRate) .. "/s",
			"  str    " .. short(STATE.strength) .. "   +" .. short(STATE.strengthRate) .. "/s",
			"  level  " .. STATE.level .. " / " .. STATE.needLevel .. " for rebirth " .. (STATE.rebirths + 1),
			"  reb    " .. STATE.rebirths .. "   cash x" .. LevelsHelper:GetCashMultiplier(STATE.rebirths) ..
				"   str x" .. LevelsHelper:GetStrengthMultiplier(STATE.rebirths),
			"  pick   " .. tostring(d.EquippedPickaxeId) .. " (" ..
				short(tonumber((PickaxeList[d.EquippedPickaxeId or ""] or {}).Strength) or 0) .. " str)",
			"  bag    " .. storage() .. " / " .. tostring(d.BackpackSize) ..
				"   sold " .. short(STATE.sold or 0) ..
				"   " .. short(STATE.incomePerMin or 0) .. "/min",
			"  walls  " .. STATE.walls .. "   ws +" .. tostring(d.ExtraWalkSpeed),
			"  target " .. STATE.targetName,
			"  loot   " .. STATE.picked .. " grabbed",
			"  " .. STATE.note,
		}
		if STATE.blocked then lines[#lines + 1] = "  blocked: " .. STATE.blocked end
		out:set(lines)
		win:SetStatus(short(STATE.cash) .. " cash   " .. short(STATE.strength) .. " str   lvl " ..
			STATE.level .. "   reb " .. STATE.rebirths .. "   " .. STATE.mode)
		task.wait(0.5)
	end
end)

win:Refresh()

--------------------------------------------------------------------------------
-- bridge handle
--------------------------------------------------------------------------------

_G.__MINECLICK_DBG = {
	CONFIG = CONFIG, STATE = STATE,
	data = data, freeLoot = freeLoot, grab = grab, think = think,
	buyPickaxe = buyPickaxe, buyAura = buyAura, buyUpgrades = buyUpgrades,
	tryRebirth = tryRebirth, claimFree = claimFree, unstuck = unstuck,
	bestTrainingArea = bestTrainingArea, workStage = workStage,
	maxUnlockedStage = maxUnlockedStage,
	nextPickaxeCost = nextPickaxeCost, canSpend = canSpend,
}

print("[mineclick] loaded - RightShift toggles the panel")
