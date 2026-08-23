--!nocheck
-- speedevolve.lua  --  "+1 Speed Evolve 🦊"  (place 83569851223739, Mauv +1)
--
-- The whole game in one sentence: every step grants Speed, Speed IS Xp so it makes
-- levels, levels plus wins buy evolutions, evolutions/trails/auras/items multiply
-- what a step is worth, and rebirths multiply everything again while resetting the
-- level. Wins come from touching the win plates at the end of the obstacle course.
--
-- Two engines, and they do NOT compete: the speed remote has no position check and
-- the win plates are pure Touched, so one Heartbeat connection runs both at once.
-- Measured together over 10s: 19,580 speed/s AND 10,000 wins/s in the same window.
--
-- Everything below is measured against leaderstats / PlayerStats, which the server
-- writes (leaderstats.Speed and .Wins are StringValues but hold the EXACT number,
-- not an abbreviation - another player read "29569824"):
--
--   * AddSpeedRemoteEvent:FireServer() takes NO arguments and credits from
--     anywhere - standing still, mid-air, 7000 studs from the map. The server caps
--     it at ~9 credited calls/s: 1 call per frame gained 36 in 4s, 5 calls per
--     frame gained 37 in the same 4s. One per Heartbeat is the entire budget.
--     The game's own SpeedClient fires it at "MoveDirection > 0 and 8 studs moved
--     and 0.1s elapsed", i.e. 10/s while running - so the cap is the legit rate.
--     Re-measured much later at tier 12 / x4000: 8.8 credits/s, and 1, 3 and 10
--     calls per frame all produced the IDENTICAL gain. One window in between read
--     25.8/s - that was a global event boost (ReplicatedStorage.GlobalBoosts
--     .SpeedMultipliers holds a NumberValue while one runs and Helper multiplies
--     by its NAME), not a higher call rate. Do not tune the loop on it.
--   * The win pin does NOT cost speed. Same 7s window, farmWins on: 70,857,142/s
--     and 11,428 wins/s; farmWins off: 70,857,142/s and no wins. Identical.
--   * Gain per call = UpgradesData[tier].Step x Helper.GetTotalMultiplier(plr),
--     and Xp rises by the same amount as Speed (level 8 -> 10 in the same 6s that
--     paid 106 speed). Speed is therefore never spent, it is the progress bar.
--   * Win plates: Workspace.Wins["1".."10"], paying WinsData 1/3/9/30/80/200/700/
--     2000/7000/20000. Pad 10 credited 20,000 from a plain CFrame pin with the
--     player at stage 0, speed 145 - there is NO stage, level or speed gate.
--     Every world ships its OWN WinsData and its own upgrade pads, which is why
--     nothing here hardcodes a number. World 2 (place 107654875426558, 5 rebirths
--     + upgrade 10) pays 60K to 1,000,000,000 per touch and carries upgrade pads
--     11-22 with Step up to 2,000,000. Measured on arrival: 985,619,427 wins/s
--     against 20,000/s in world 1, and the panel went from x4,500 to x660,000
--     multiplier and 2.45T speed/s inside half a minute.
--     Holding still pays ONCE (0 in 3s): Touched needs the parts to separate, so
--     the pin flips on/off every frame. Cooldown is per PLAYER, not per pad -
--     alternating two pads measured 9,250/s against 10,000/s on the single best.
--   * Upgrades are a LADDER and they COST wins: the pad only answers for tier
--     owned+1 (pad 6 ignored us at tier 2), and buying tier 2 moved the balance
--     180,003 -> 180,000, exactly UpgradesData[2].Cost.
--   * Evolutions: EvolutionRemoteEvent {Action="Evolve"} advances ONE step, gated
--     by Level and charged WinsCost. 64 of them, Cockroach x1 -> Pteranodon x1550.
--   * Rebirth: RebirthRemoteEvent:FireServer(), no arguments. Verified reset:
--     Speed 41353 -> 0, Xp -> 0, Level 37 -> 1. KEPT: wins, all 10 upgrades and
--     the evolution. Multiplier is Helper.GetRebirthMultiplier = rebirths + 1.
--     Level required = (r+1)*25 up to r=7, then (r-7)*50+200.
--   * Trails / auras / items all cost WINS and multiply: {Action="Buy"/"Equip"/
--     "Unequip", TrailName=/AuraName=/ItemName=}. Blue trail charged exactly
--     25,000 (115,389 -> 90,389) and equipping it doubled the step.
--     Items are ADDITIVE among themselves - Helper does max(1, sum(qty*mult)) -
--     and then multiply the rest, plus an {Action="EquipBest"} that needs no args.
--
-- Deliberately NOT used, each for a measured reason:
--   * Treadmills. They look like the multiplier they advertise but they THROTTLE a
--     script: same 5s window, no treadmill 47,520/s, Rebirth1 (x1.5) 46,640/s,
--     Basic 37,620/s. The game grants its own ticks there and ours are worth more.
--   * PlayerRemoteEvent {Action="Teleport", StageNumber=n} works but charges wins
--     (259,999 -> 259,879). A CFrame write goes to the same place for free.
--   * Every Robux path: Workspace.SkipStages, Workspace.DoubleWins,
--     GamepassEvolutions, PromptProductRemoteEvent, PromptGamepassRemoteEvent,
--     the "Double Offline Speed" and "2x Wins" buttons and the gamepass
--     treadmills (Gold/Emerald/Diamond/Ruby). The panel cannot reach any of them.
--   * The group boost needs membership in group 860201727 - that is the user's
--     decision, so it is a button and not a loop.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local plr = Players.LocalPlayer
local Shared = ReplicatedStorage:WaitForChild("Modules", 10):WaitForChild("Shared", 10)
local Remotes = Shared:WaitForChild("RemoteEventService", 10)

local AddSpeed    = Remotes:WaitForChild("AddSpeedRemoteEvent", 10)
local EvolutionRE = Remotes:WaitForChild("EvolutionRemoteEvent", 10)
local RebirthRE   = Remotes:WaitForChild("RebirthRemoteEvent", 10)
local TrailRE     = Remotes:WaitForChild("TrailRemoteEvent", 10)
local AuraRE      = Remotes:WaitForChild("AuraRemoteEvent", 10)
local ItemRE      = Remotes:WaitForChild("ItemRemoteEvent", 10)
local PlayerRE    = Remotes:WaitForChild("PlayerRemoteEvent", 10)
local DailyRE     = Remotes:WaitForChild("DailyLoginRemoteEvent", 10)
local CodesRE     = Remotes:WaitForChild("CodesRemoteEvent", 10)
local WorldsRE    = Remotes:WaitForChild("WorldsRemoteEvent", 10)

local Helper        = require(Shared.Helper)
local UpgradesData  = require(Shared.UpgradesData)
local EvolutionData = require(Shared.EvolutionData)
local WinsData      = require(Shared.WinsData)
local TrailData     = require(Shared.TrailData)
local AuraData      = require(Shared.AuraData)
local ItemData      = require(Shared.ItemData)
local WorldsData    = require(Shared.WorldsData)

local PS = plr:WaitForChild("PlayerStats", 10)

--------------------------------------------------------------------------------
-- config / state
--------------------------------------------------------------------------------

local CONFIG = {
	auto = false,           -- master switch
	farmSpeed = true,       -- one AddSpeed per Heartbeat, the whole budget
	farmWins = true,        -- flip on/off the best win plate every frame
	winPad = 0,             -- 0 = highest plate that exists in this world

	autoEvolve = true,      -- the biggest ladder in the game, level + wins gated
	autoRebirth = true,     -- x(rebirths+1) on everything, wipes the level
	autoUpgrade = true,     -- the Step ladder, sequential and paid in wins
	autoTrail = true,
	autoAura = true,
	autoItems = true,       -- the bag: additive multipliers + EquipBest
	autoFree = true,        -- daily login, offline speed
	autoWorld = false,      -- OFF: this teleports to a different PlaceId
	useTreadmill = false,   -- park on the best free treadmill INSTEAD of the plate

	evolveReserve = true,   -- never spend the wins the next evolution needs
	rebirthHold = 45,       -- seconds of win income to wait for a reachable evolve
	rebirthStop = 0,        -- 0 = never stop rebirthing
}

local STATE = {
	note = "idle",
	phase = "idle",
	winTarget = nil,        -- Vector3 the pin flips on and off
	winPadName = "-",
	treadTarget = nil,
	treadName = "-",
	errand = nil,           -- {pos = Vector3} takes the body over from the farm
	uiOwner = nil,
	wins = 0, speed = 0, level = 0, rebirths = 0,
	winsRate = 0, speedRate = 0,
	lastWins = 0, lastSpeed = 0, lastAt = 0,
	evolveName = "?", evolveMult = 1, multiplier = 1,
	bought = 0,
	blocked = nil,
}

-- Re-executing does not restart the Lua VM. Every loop and the pin capture this
-- and exit the moment it stops matching, which is what stops doubled loops.
_G.__SPEEDEVO = (_G.__SPEEDEVO or 0) + 1
local GEN = _G.__SPEEDEVO

--------------------------------------------------------------------------------
-- reading the server's view
--------------------------------------------------------------------------------

-- leaderstats.Speed / .Wins are StringValues holding the exact integer.
local function wins() return tonumber(plr.leaderstats.Wins.Value) or 0 end
local function speed() return tonumber(plr.leaderstats.Speed.Value) or 0 end
local function level() return PS.Level.Value end
local function rebirths() return plr.leaderstats.Rebirths.Value end

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
-- the pin - one connection drives both engines
--------------------------------------------------------------------------------

-- The plates pay on Touched and Touched only fires again once the parts have
-- separated, so a still body is paid exactly once (measured: 0 wins in 3s while
-- holding, 20,000 per ~2s while flipping). 40 studs up is far enough to separate
-- and near enough that the pad never streams out.
local FLIP_UP = Vector3.new(0, 40, 0)

local pinConn
local function startPin()
	if pinConn then pinConn:Disconnect() end
	local flip = 0
	pinConn = RunService.Heartbeat:Connect(function()
		if GEN ~= _G.__SPEEDEVO then pinConn:Disconnect() return end
		if not CONFIG.auto then return end

		-- No position check on this one, so it runs during errands too.
		if CONFIG.farmSpeed then AddSpeed:FireServer() end

		local hrp = root()
		if not hrp then return end
		flip = flip + 1

		local errand = STATE.errand
		if errand then
			hrp.CFrame = CFrame.new(flip % 6 < 3 and errand.pos or (errand.pos + Vector3.new(0, 12, 0)))
			return
		end
		-- The treadmill has to be STOOD on, so it is an either/or with the plate.
		if CONFIG.useTreadmill and STATE.treadTarget then
			hrp.CFrame = CFrame.new(STATE.treadTarget)
			return
		end
		if CONFIG.farmWins and STATE.winTarget then
			hrp.CFrame = CFrame.new(flip % 2 == 0 and STATE.winTarget or (STATE.winTarget + FLIP_UP))
		end
	end)
end

--------------------------------------------------------------------------------
-- the win plates
--------------------------------------------------------------------------------

-- Workspace.StreamingEnabled is true, so a distant plate is an empty Model - but
-- GetPivot still answers, which is all the pin needs. Nothing here waits for parts.
local function padPosition(model)
	local ok, pivot = pcall(function() return model:GetPivot().Position end)
	if not ok then return nil end
	return pivot + Vector3.new(0, 5, 0)
end

local function retargetWins()
	local folder = Workspace:FindFirstChild("Wins")
	if not folder then STATE.blocked = "no Workspace.Wins" return end

	local best, bestValue, bestPos = nil, -1, nil
	for _, model in ipairs(folder:GetChildren()) do
		local index = tonumber(model.Name)
		if index then
			local value = WinsData[index] or index
			if CONFIG.winPad > 0 then
				if index == CONFIG.winPad then best, bestValue, bestPos = model.Name, value, padPosition(model) end
			elseif value > bestValue then
				local pos = padPosition(model)
				if pos then best, bestValue, bestPos = model.Name, value, pos end
			end
		end
	end
	if not bestPos then return end
	STATE.winTarget = bestPos
	STATE.winPadName = "plate " .. best .. " (" .. short(bestValue) .. "/touch)"
	STATE.blocked = nil
end

-- Treadmills, measured rather than believed. They do NOT multiply our calls -
-- the server runs its own tick there and ours lose out, so the advertised
-- multiplier is not what shows up on the balance. Same 5s window, same tier:
--   no treadmill  47,520/s        no treadmill  91.6M/s and 94.9M/s (control)
--   Basic   x1    37,620/s  -21%  Rebirth3 x2   101.2M/s  +8%
--   Rebirth1 x1.5 46,640/s   -2%
-- So the only tier that is worth anything is a high one, it is worth single
-- digit percent, and standing there costs the ENTIRE win farm (20K wins/s).
-- Hence the toggle, and hence it is off.
local TreadmillData = require(Shared.TreadmillData)

local function retargetTreadmill()
	local folder = Workspace:FindFirstChild("Treadmills")
	if not folder then return end
	local reb = rebirths()
	local best, bestMult, bestPos = nil, -1, nil
	for _, model in ipairs(folder:GetChildren()) do
		local entry = TreadmillData[model.Name]
		-- GamepassName means Robux, and the panel never touches those.
		if entry and not entry.GamepassName and reb >= (entry.RebirthsRequired or 0) then
			local part = model:FindFirstChild("TouchPart")
			if part and (entry.Multiplier or 0) > bestMult then
				best, bestMult, bestPos = model.Name, entry.Multiplier, part.Position + Vector3.new(0, 4, 0)
			end
		end
	end
	if bestPos then
		STATE.treadTarget = bestPos
		STATE.treadName = best .. " x" .. bestMult
	end
end

--------------------------------------------------------------------------------
-- spending rules
--------------------------------------------------------------------------------

-- The evolution ladder is the priority the user set, so it is also the reserve:
-- nothing else is allowed to spend the wins the next evolution needs. The usual
-- escape hatch applies - a purchase that is trivial next to the balance is never
-- worth blocking, or a 25K trail waits behind a 310T evolution forever.
local function nextEvolution()
	local index = PS.EvolutionProgress.Value + 1
	local name = EvolutionData.Order[index]
	if not name then return nil end
	return name, EvolutionData.Evolutions[name], index
end

local function evolveReserve()
	if not CONFIG.evolveReserve then return 0 end
	local _, entry = nextEvolution()
	if not entry then return 0 end
	-- Only fence off what the level actually allows us to buy soon; reserving for
	-- an evolution 200 levels away would freeze every other purchase in the game.
	if entry.Level > level() * 2 then return 0 end
	return entry.WinsCost or 0
end

local function canSpend(cost)
	local balance = STATE.wins
	if cost > balance then return false end
	if cost <= balance * 0.01 then return true end
	return balance - cost >= evolveReserve()
end

--------------------------------------------------------------------------------
-- actions
--------------------------------------------------------------------------------

-- One step per call, gated by Level and charged WinsCost. Several can be
-- affordable at once after a long win farm, so this drains what it can.
local function tryEvolve()
	if not CONFIG.autoEvolve then return end
	for _ = 1, 6 do
		local name, entry = nextEvolution()
		if not entry then STATE.note = "evolutions maxed (" .. PS.EvolutionSelected.Value .. ")" return end
		if level() < entry.Level or wins() < (entry.WinsCost or 0) then return end
		EvolutionRE:FireServer({ Action = "Evolve" })
		task.wait(0.6)
		if PS.EvolutionSelected.Value ~= name then return end
		STATE.note = "evolve " .. name .. " x" .. entry.SpeedMultiplier ..
			" for " .. short(entry.WinsCost or 0)
	end
end

-- Rebirth wipes the level, and the level is what unlocks the next evolution. So
-- it waits when that evolution is already level-eligible and the win balance is
-- within rebirthHold seconds of paying for it - otherwise the wipe throws away
-- exactly the thing the rebirth was supposed to accelerate.
local function evolutionWithinReach()
	local _, entry = nextEvolution()
	if not entry then return false end
	if level() < entry.Level then return false end
	local missing = (entry.WinsCost or 0) - STATE.wins
	if missing <= 0 then return true end
	if STATE.winsRate <= 0 then return false end
	return missing / STATE.winsRate <= CONFIG.rebirthHold
end

local function tryRebirth()
	if not CONFIG.autoRebirth then return end
	local have = rebirths()
	if CONFIG.rebirthStop > 0 and have >= CONFIG.rebirthStop then return end
	local need = Helper.GetRebirthLevelRequired(have)
	if level() < need then return end
	if evolutionWithinReach() then
		STATE.note = "holding rebirth for evolve " .. tostring(select(1, nextEvolution()))
		return
	end
	RebirthRE:FireServer()
	task.wait(1)
	if rebirths() > have then
		STATE.note = "rebirth " .. rebirths() .. " at level " .. need ..
			"  x" .. Helper.GetRebirthMultiplier(rebirths())
	end
end

-- The pads only answer for tier owned+1 and they charge UpgradesData[tier].Cost,
-- so this walks the ladder one rung at a time. It has to take the body away from
-- the win plate, which is what the errand is for.
local function buyUpgrades()
	if not CONFIG.autoUpgrade then return end
	local folder = Workspace:FindFirstChild("UpgradeButtons")
	if not folder then return end

	for _ = 1, 12 do
		local tier = PS.UpgradeSelected.Value + 1
		local entry = UpgradesData[tier]
		if not entry then return end
		if not canSpend(entry.Cost or math.huge) then return end
		local model = folder:FindFirstChild(tostring(tier))
		if not model then return end

		local pos = padPosition(model)
		if not pos then return end
		pcall(function() plr:RequestStreamAroundAsync(pos) end)
		STATE.phase = "upgrade " .. tier
		STATE.errand = { pos = pos - Vector3.new(0, 1, 0) }

		local deadline = os.clock() + 5
		repeat task.wait(0.15) until PS.UpgradeSelected.Value >= tier or os.clock() > deadline
		STATE.errand = nil
		STATE.phase = "farm"

		if PS.UpgradeSelected.Value < tier then
			STATE.blocked = "upgrade pad " .. tier .. " did not answer"
			return
		end
		STATE.note = "upgrade " .. tier .. " +" .. short(entry.Step) .. "/step for " .. short(entry.Cost)
	end
end

local function ownedFolder(name)
	return plr:FindFirstChild(name)
end

local function equippedMulti(config, valueName)
	local entry = config[PS[valueName].Value]
	return entry and entry.SpeedMultiplier or 0
end

-- Best affordable that beats what is worn - never below it. "Best unowned and
-- affordable" is how a x2 gets bought while a x5 is equipped.
local function bestBuy(config, folder, floor)
	local pick, pickMulti = nil, floor or 0
	for name, entry in pairs(config) do
		local multi = entry.SpeedMultiplier or 0
		if folder and not folder:FindFirstChild(name) and multi > pickMulti and canSpend(entry.WinsCost or math.huge) then
			pick, pickMulti = name, multi
		end
	end
	return pick, pickMulti
end

local function bestOwned(config, folder)
	local pick, pickMulti = nil, 0
	for _, entry in ipairs(folder:GetChildren()) do
		local cfg = config[entry.Name]
		if cfg and (cfg.SpeedMultiplier or 0) > pickMulti then pick, pickMulti = entry.Name, cfg.SpeedMultiplier end
	end
	return pick
end

local function buyWearable(config, folder, remote, key, valueName, label)
	if not folder then return end
	local pick, multi = bestBuy(config, folder, equippedMulti(config, valueName))
	if pick then
		remote:FireServer({ Action = "Buy", [key] = pick })
		STATE.bought = STATE.bought + 1
		STATE.note = label .. " " .. pick .. " x" .. multi .. " for " .. short(config[pick].WinsCost)
		task.wait(0.8)
	end
	local wear = bestOwned(config, folder)
	if wear and PS[valueName].Value ~= wear then
		remote:FireServer({ Action = "Equip", [key] = wear })
	end
end

local function buyTrail()
	if not CONFIG.autoTrail then return end
	buyWearable(TrailData, ownedFolder("TrailsOwned"), TrailRE, "TrailName", "TrailEquipped", "trail")
end

local function buyAura()
	if not CONFIG.autoAura then return end
	buyWearable(AuraData, ownedFolder("AurasOwned"), AuraRE, "AuraName", "AuraEquipped", "aura")
end

-- The bag is the odd one out: Helper sums qty x multiplier over ItemsEquipped and
-- only then multiplies, so a second copy of the same item is worth buying and
-- "best owned" is not the rule. Buy whatever the surplus covers, then let the
-- game's own EquipBest sort the slots out.
local function buyItems()
	if not CONFIG.autoItems then return end
	local pick, pickMulti = nil, 0
	for name, entry in pairs(ItemData) do
		local multi = entry.SpeedMultiplier or 0
		if multi > pickMulti and canSpend(entry.WinsCost or math.huge) then
			pick, pickMulti = name, multi
		end
	end
	if pick then
		ItemRE:FireServer({ Action = "Buy", ItemName = pick })
		STATE.bought = STATE.bought + 1
		STATE.note = "item " .. pick .. " x" .. pickMulti .. " for " .. short(ItemData[pick].WinsCost)
		task.wait(0.8)
	end
	-- EquipBest on an empty bag answers with a red "You don't own any items!"
	-- notification every single pass, which reads like a broken routine. The
	-- cheapest item is 50B wins, so an empty bag is the normal early state.
	local bag = ownedFolder("ItemsOwned")
	if bag and #bag:GetChildren() > 0 then
		ItemRE:FireServer({ Action = "EquipBest" })
	end
end

local function claimFree()
	if not CONFIG.autoFree then return end
	if (tonumber(PS.PendingOfflineSpeed.Value) or 0) > 0 or plr:GetAttribute("OfflineSpeedReady") then
		PlayerRE:FireServer({ Action = "ClaimOfflineSpeed" })
	end
	local daily = plr:FindFirstChild("DailyLogin")
	if daily and daily.TodayClaimed.Value == false then
		DailyRE:FireServer({ Action = "Ready" })
		task.wait(0.4)
		DailyRE:FireServer({ Action = "Claim", Day = daily.CurrentDay.Value })
		task.wait(0.4)
		if daily.TodayClaimed.Value then STATE.note = "daily login day " .. daily.CurrentDay.Value end
	end
end

-- Every world is its own PlaceId, so this LEAVES the game. Off by default for
-- that reason. The gates are both real: rebirths and the upgrade tier.
local function worldTarget()
	local best, bestNum = nil, 1
	local reb, upg = rebirths(), PS.UpgradeSelected.Value
	for name, entry in pairs(WorldsData) do
		local num = tonumber(name:match("%d+")) or 1
		if reb >= (entry.RebirthsRequired or 0) and upg >= (entry.UpgradeRequired or 0) and num > bestNum then
			best, bestNum = name, num
		end
	end
	return best, bestNum
end

local function tryWorld()
	if not CONFIG.autoWorld then return end
	local want, num = worldTarget()
	if not want then return end
	local hereNum = 1
	for name, entry in pairs(WorldsData) do
		if entry.PlaceId == game.PlaceId then hereNum = tonumber(name:match("%d+")) or 1 end
	end
	if num <= hereNum then return end
	-- The next world is a different PlaceId, so nothing in this VM survives the
	-- jump. Arm the hub loader first - it is what brings this script back up on
	-- the other side, and it re-arms itself for the world after that.
	pcall(function()
		queue_on_teleport('loadstring(game:HttpGet("https://raw.githubusercontent.com/' ..
			'seltonmt012/sel01-rbx/main/loader.lua"))()')
	end)
	STATE.note = "teleporting to " .. want
	WorldsRE:FireServer(want)
end

-- The client checks IsInGroupAsync(860201727) before firing this, so it only pays
-- once the account has joined the group. That is the user's call, not the panel's.
local function groupBoost()
	PlayerRE:FireServer({ Action = "GiveGroupBoost" })
	task.wait(1)
	STATE.note = "group boost multiplier " .. tostring(PS.GroupBoostMultiplier.Value)
end

-- No code list ships on the client: a debug.getconstants sweep found none, and the
-- place description carries none either. CodesRemoteEvent takes the plain string,
-- so anything the user learns from the socials goes into this table.
local CODES = {}

local function redeemCodes()
	if #CODES == 0 then
		STATE.note = "no codes known - add them to CODES in the script"
		return
	end
	for _, code in ipairs(CODES) do
		CodesRE:FireServer(code)
		task.wait(0.6)
	end
	STATE.note = "redeemed " .. #CODES .. " codes"
end

local function unstuck()
	CONFIG.auto = false
	STATE.errand = nil
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
	local spawnPoint = Workspace:FindFirstChild("SpawnLocation")
	if hrp and spawnPoint then hrp.CFrame = CFrame.new(spawnPoint.Position + Vector3.new(0, 6, 0)) end
	STATE.note = "unstuck, auto off"
end

--------------------------------------------------------------------------------
-- loops
--------------------------------------------------------------------------------

local function loop(interval, key, fn)
	task.spawn(function()
		while GEN == _G.__SPEEDEVO do
			if CONFIG.auto and (key == nil or CONFIG[key]) then
				local ok, err = pcall(fn)
				if not ok then STATE.note = tostring(err) end
			end
			task.wait(interval)
		end
	end)
end

-- fast: the numbers, the target and the two ladders the user called the important
-- ones. Evolve runs before rebirth on purpose - the rebirth wipes the level that
-- the evolution needs.
loop(1, nil, function()
	STATE.wins, STATE.speed = wins(), speed()
	STATE.level, STATE.rebirths = level(), rebirths()

	local now = os.clock()
	if STATE.lastAt > 0 and now > STATE.lastAt then
		local dt = now - STATE.lastAt
		-- Only positive samples count. Spending drops the balance and an errand
		-- pauses the plate entirely, and a rate that falls to zero on those
		-- samples would make rebirthHold think no income exists at all.
		local wr = (STATE.wins - STATE.lastWins) / dt
		local sr = (STATE.speed - STATE.lastSpeed) / dt
		if wr > 0 then STATE.winsRate = STATE.winsRate > 0 and (STATE.winsRate * 0.6 + wr * 0.4) or wr end
		if sr > 0 then STATE.speedRate = STATE.speedRate > 0 and (STATE.speedRate * 0.6 + sr * 0.4) or sr end
	end
	STATE.lastWins, STATE.lastSpeed, STATE.lastAt = STATE.wins, STATE.speed, now

	local name, entry = nextEvolution()
	STATE.evolveName = name or "max"
	STATE.evolveMult = entry and entry.SpeedMultiplier or 0
	local ok, multiplier = pcall(Helper.GetTotalMultiplier, plr)
	STATE.multiplier = ok and multiplier or 1

	if not STATE.errand then
		if CONFIG.useTreadmill then retargetTreadmill() else retargetWins() end
	end
	if STATE.phase == "idle" then STATE.phase = "farm" end

	tryEvolve()
	tryRebirth()

	-- Re-read after the actions: a pass can burn six evolutions, and a read-out
	-- still naming the one that was bought a second ago reads like a stuck loop.
	local after, afterEntry = nextEvolution()
	STATE.evolveName = after or "max"
	STATE.evolveMult = afterEntry and afterEntry.SpeedMultiplier or 0
end)

-- slow: everything that spends, plus the errand that has to leave the plate
loop(12, nil, function()
	withUI("spend", function()
		buyUpgrades()
		buyTrail()
		buyAura()
		buyItems()
		claimFree()
		tryWorld()
	end)
end)

startPin()

--------------------------------------------------------------------------------
-- panel
--------------------------------------------------------------------------------

local UI = (_G.__SEL and _G.__SEL.ui) or loadstring(readfile("ui-template.lua"))()

if _G.__SPEEDEVO_WIN then pcall(function() _G.__SPEEDEVO_WIN:Destroy() end) end

-- Every switch on this panel survives a rejoin. UI.config merges the saved file
-- into CONFIG HERE, before the panel is built - the controls read their initial
-- value out of CONFIG when they are created, so they come up on the saved state
-- by themselves and nothing below had to be told about any of this.
UI.config("speedevolve", CONFIG)

local win = UI.Window({
	title = "SPEED", accentTitle = "EVOLVE", subtitle = "seltonmt",
	badge = "🦊", width = 920, height = 580,
})
_G.__SPEEDEVO_WIN = win

local farm = win:Page("FARM", UI.icon.bolt)

local main = farm:Card("LOOP", 1)
main:Toggle("AUTO", CONFIG.auto, function(v)
	CONFIG.auto = v
	STATE.note = v and "running" or "stopped"
end, "one Heartbeat drives both engines at once", UI.theme.good)
main:Toggle("Farm speed", CONFIG.farmSpeed, function(v) CONFIG.farmSpeed = v end,
	"AddSpeed once per frame, the server caps it at ~9/s")
main:Toggle("Farm wins", CONFIG.farmWins, function(v) CONFIG.farmWins = v end,
	"flips on and off the plate - holding still pays once")
main:Toggle("Use treadmill", CONFIG.useTreadmill, function(v)
	CONFIG.useTreadmill = v
	STATE.note = v and "treadmill instead of the win plate" or "back on the win plate"
end, "measured: Basic -21%, Rebirth1 -2%, Rebirth3 +8% - and no wins at all", UI.theme.bad)
main:Stepper("Win plate", function()
	return CONFIG.winPad == 0 and "Auto (best)" or ("Plate " .. CONFIG.winPad)
end, function(dir)
	CONFIG.winPad = math.clamp(CONFIG.winPad + dir, 0, 10)
end, "0 = the highest paying plate in this world")

local prog = farm:Card("PROGRESSION", 2)
prog:Toggle("Auto evolve", CONFIG.autoEvolve, function(v) CONFIG.autoEvolve = v end,
	"64 steps, Cockroach x1 to Pteranodon x1550, level + wins", UI.theme.warn)
prog:Toggle("Auto rebirth", CONFIG.autoRebirth, function(v) CONFIG.autoRebirth = v end,
	"x(rebirths+1), wipes level and speed, keeps wins and upgrades", UI.theme.warn)
prog:Toggle("Auto upgrade", CONFIG.autoUpgrade, function(v) CONFIG.autoUpgrade = v end,
	"the Step ladder - sequential pads, paid in wins", UI.theme.warn)
prog:Stepper("Rebirth hold", function() return CONFIG.rebirthHold .. "s" end,
	function(dir) CONFIG.rebirthHold = math.clamp(CONFIG.rebirthHold + dir * 15, 0, 300) end,
	"wait this long for an evolve the level already allows")
prog:Stepper("Stop at rebirth", function()
	return CONFIG.rebirthStop == 0 and "never" or tostring(CONFIG.rebirthStop)
end, function(dir) CONFIG.rebirthStop = math.clamp(CONFIG.rebirthStop + dir, 0, 60) end,
	"0 keeps rebirthing forever")

local spend = farm:Card("WINS SPENDING", 1)
spend:Toggle("Auto trail", CONFIG.autoTrail, function(v) CONFIG.autoTrail = v end,
	"Blue x2 @25K up to Sun x400 @25T", UI.theme.warn)
spend:Toggle("Auto aura", CONFIG.autoAura, function(v) CONFIG.autoAura = v end,
	"Blue x2 @1M up to Super Saiyan x400 @1Qa, stacks with the trail", UI.theme.warn)
spend:Toggle("Auto bag", CONFIG.autoItems, function(v) CONFIG.autoItems = v end,
	"items add up with each other, then EquipBest", UI.theme.warn)
spend:Toggle("Keep evolve reserve", CONFIG.evolveReserve, function(v) CONFIG.evolveReserve = v end,
	"nothing else spends the wins the next evolution needs")

local extra = farm:Card("EXTRAS", 2)
extra:Toggle("Claim free", CONFIG.autoFree, function(v) CONFIG.autoFree = v end,
	"offline speed and the daily login ladder")
extra:Toggle("Auto world", CONFIG.autoWorld, function(v) CONFIG.autoWorld = v end,
	"W2 at 5 rebirths + upgrade 10 - this LEAVES the place", UI.theme.bad)
extra:Button("Group boost", function() task.spawn(groupBoost) end)
extra:Label("group boost needs membership in 860201727")
extra:Button("Redeem codes", function() task.spawn(redeemCodes) end)
extra:Button("Unstuck", unstuck, UI.theme.bad)
extra:Label("treadmills are skipped: measured slower than no treadmill")

local out = farm:Card("STATUS", 0):Readout(12, function(text)
	if text:find("blocked") then return UI.theme.bad end
	if text:find("^AUTO") then return UI.theme.good end
	return nil
end)

task.spawn(function()
	while GEN == _G.__SPEEDEVO do
		local lines = {
			(CONFIG.auto and "AUTO ON" or "AUTO OFF") .. "   " .. STATE.phase,
			"  speed  " .. short(STATE.speed) .. "   +" .. short(STATE.speedRate) .. "/s",
			"  wins   " .. short(STATE.wins) .. "   +" .. short(STATE.winsRate) .. "/s",
			"  level  " .. STATE.level .. "   rebirth " .. STATE.rebirths ..
				"   x" .. short(STATE.multiplier),
			"  step   tier " .. PS.UpgradeSelected.Value .. " +" ..
				short((UpgradesData[PS.UpgradeSelected.Value] or {}).Step or 0),
			"  now    " .. PS.EvolutionSelected.Value .. "  ->  " .. STATE.evolveName ..
				" x" .. STATE.evolveMult,
			"  spot   " .. (CONFIG.useTreadmill and ("treadmill " .. STATE.treadName) or STATE.winPadName),
			"  worn   " .. PS.TrailEquipped.Value .. " / " .. PS.AuraEquipped.Value,
			"  bought " .. STATE.bought,
			"  " .. STATE.note,
		}
		if STATE.blocked then lines[#lines + 1] = "  blocked: " .. STATE.blocked end
		out:set(lines)
		win:SetStatus(short(STATE.speed) .. " speed   " .. short(STATE.wins) .. " wins   lvl " ..
			STATE.level .. "   reb " .. STATE.rebirths .. "   " .. PS.EvolutionSelected.Value)
		task.wait(0.5)
	end
end)

-- Der Home-Tab: das GitHub-Commit-Log als Changelog plus der aktuelle Lauf.
-- Zuletzt deklariert, aber das Template schiebt ihn an den Anfang der Leiste -
-- er ist immer das erste Icon und die Seite, auf der das Panel aufgeht.
pcall(function() win:Home() end)

win:Refresh()

--------------------------------------------------------------------------------
-- bridge handle
--------------------------------------------------------------------------------

_G.__SPEEDEVO_DBG = {
	CONFIG = CONFIG, STATE = STATE,
	tryEvolve = tryEvolve, tryRebirth = tryRebirth, buyUpgrades = buyUpgrades,
	buyTrail = buyTrail, buyAura = buyAura, buyItems = buyItems,
	claimFree = claimFree, tryWorld = tryWorld, groupBoost = groupBoost,
	redeemCodes = redeemCodes, unstuck = unstuck, retargetWins = retargetWins,
	canSpend = canSpend, evolveReserve = evolveReserve, nextEvolution = nextEvolution,
}

print("[speedevolve] loaded - RightShift toggles the panel")
