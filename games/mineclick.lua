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
--   * **Loot never enters the inventory - it pays cash on the spot.** That is
--     what cost the longest detour here: `Data.Inventory` stayed empty through
--     every wall, every tutorial step and every SellAllLoot, while the actual
--     earner is the loot lying at `Stages["Stage n"].Spawnpoints.<GUID>`. Those
--     parts carry `ItemId`, `StageId` and `IsTaken`; touching one with
--     `IsTaken == false` credits its Revenue immediately. Measured: 17 pickups
--     in 16s moved Cash 200,000,100 -> 200,001,978.
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
	autoMine = true,         -- stand in the stage hitbox, the client breaks the walls
	autoTrain = true,        -- park in the best free training area when idle
	autoPickaxe = true,
	autoAura = true,
	autoUpgrade = true,      -- backpack + walkspeed
	autoRebirth = true,
	lootRange = 0,           -- 0 = the whole map, otherwise studs from the character
	pickaxeReserve = true,   -- keep the cash the next pickaxe needs
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
local function freeLoot()
	local out = {}
	local hrp = root()
	local from = hrp and hrp.Position
	local stages = Workspace:FindFirstChild("Stages")
	if not stages then return out end
	for _, stage in ipairs(stages:GetChildren()) do
		local spawns = stage:FindFirstChild("Spawnpoints")
		if spawns then
			for _, part in ipairs(spawns:GetChildren()) do
				if part:IsA("BasePart") and part:GetAttribute("IsTaken") == false then
					local dist = from and (part.Position - from).Magnitude or 0
					if CONFIG.lootRange <= 0 or dist <= CONFIG.lootRange then
						out[#out + 1] = { part = part, dist = dist }
					end
				end
			end
		end
	end
	table.sort(out, function(a, b) return a.dist < b.dist end)
	return out
end

local function itemValue(part)
	local id = part:GetAttribute("ItemId")
	local entry = id and ItemsList[id]
	return entry and entry.Revenue or 0, id
end

-- Touch is what pays. A ProximityPrompt exists on some of them but only once the
-- client has built it, so the touch path is the reliable one and the prompt is
-- fired as a second chance.
local function grab(part)
	local hrp = root()
	if not hrp or not part.Parent then return false end
	STATE.target = part.Position + Vector3.new(0, 2, 0)
	local _, id = itemValue(part)
	STATE.targetName = "loot " .. tostring(id)
	task.wait(0.35)
	pcall(function()
		firetouchinterest(hrp, part, 0)
		firetouchinterest(hrp, part, 1)
	end)
	local prompt = part:FindFirstChildOfClass("ProximityPrompt")
	if prompt then pcall(fireproximityprompt, prompt) end
	task.wait(0.15)
	if part:GetAttribute("IsTaken") ~= false then
		STATE.picked = STATE.picked + 1
		return true
	end
	return false
end

--------------------------------------------------------------------------------
-- mining
--------------------------------------------------------------------------------

-- The deepest stage whose hitbox exists. Standing in it is the entire job: the
-- game's own StageClient zone handler picks the next unbroken wall and swings.
local function deepestStage()
	local stages = Workspace:FindFirstChild("Stages")
	if not stages then return nil end
	local best, bestNum = nil, 0
	for _, folder in ipairs(stages:GetChildren()) do
		local num = tonumber(folder.Name:match("%d+"))
		local hitbox = folder:FindFirstChild("Hitbox")
		if num and hitbox and num > bestNum then
			-- only stages the player has actually reached; StagesUnlocked is the
			-- server's own record and TeleportToStage refuses the rest
			if (data().StagesUnlocked or {})[num] or (data().StagesUnlocked or {})[tostring(num)] or num == 1 then
				best, bestNum = hitbox, num
			end
		end
	end
	return best, bestNum
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

local function buyUpgrades()
	if not CONFIG.autoUpgrade then return end
	local d = data()
	local size = d.BackpackSize or 3
	if size < (UpgradesHelper.MaxBackpackSize or 20) then
		local cost = UpgradesHelper:GetBackpackUpgradeCost(size)
		if canSpend(cost) then
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
local function think()
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

	local hitbox, stageNum = deepestStage()
	if CONFIG.autoMine and hitbox and wallsLeft(stageNum) then
		STATE.mode = "mine"
		STATE.stage = stageNum
		STATE.target = hitbox.Position
		STATE.targetName = "stage " .. stageNum .. " (walls open)"
		task.wait(1)
		return
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
main:Toggle("Auto mine", CONFIG.autoMine, function(v) CONFIG.autoMine = v end,
	"stands in the deepest stage hitbox, the game breaks the walls")
main:Toggle("Auto train", CONFIG.autoTrain, function(v) CONFIG.autoTrain = v end,
	"best free area: Coal x1.5 up to Demonite x10")
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
			"  walls  " .. STATE.walls .. "   bag " .. tostring(d.BackpackSize) ..
				"   ws +" .. tostring(d.ExtraWalkSpeed),
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
	bestTrainingArea = bestTrainingArea, deepestStage = deepestStage,
	nextPickaxeCost = nextPickaxeCost, canSpend = canSpend,
}

print("[mineclick] loaded - RightShift toggles the panel")
