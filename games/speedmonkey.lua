--!nocheck
-- speedmonkey.lua  --  "🐒 +1 Speed Monkey Escape"  (place 114697347887839)
--
-- The whole game in one sentence: you run, every 0.25s of running grants XP
-- multiplied by your equipped upgrade, XP makes levels, levels make rebirths,
-- rebirths unlock worlds, and touching a stage's win plate pays wins - which is
-- the requirement (never the cost) of the next upgrade.
--
-- Everything below was measured against the server through Player.Data, which is
-- the state oracle in this game: Level, Xp, Wins, Rebirths, World, Charms and the
-- charm shop all live there as real ValueBase objects that the server writes.
--
-- Measured, all of it, with the automation off:
--   * NormalWin.Button carries a TouchInterest. Pinning the HumanoidRootPart on
--     it pays. World1 Stage1 = +1, Stage3 = +20, Stage9 = +200K, and the payout
--     is that figure times the win multiplier (measured x2 here, so +400,000).
--   * THE PLATE NOW HAS A ~13 SECOND PER-PLAYER COOLDOWN, re-measured 2026-08-20.
--     It used to pay every ~1.1s and that number is dead. Four independent runs
--     with the automation off gave gaps of 13.23 / 13.07 / 12.77 / 13.09s, so the
--     cadence is 13.0s +-0.3 and nothing shortens it:
--       - movement makes no difference (hum:Move on and off both gave 13.1s),
--       - separating the parts every 4 frames makes no difference,
--       - leaving to Checkpoint8 and coming back makes no difference,
--       - firetouchinterest credits exactly NOTHING (the server validates the
--         touch), so it cannot be driven faster than the body can be there,
--       - the pin height does not matter: +0 and +4 studs both pay at 13.1s.
--     So World1 Stage9 is 400,000 / 13.0s = ~30.8K wins/s, against the ~180K/s
--     this file used to measure. The lever is no longer the cadence, it is the
--     plate's VALUE - World2 Stage9 pays 1e12 per touch, five million times more.
--   * WORLD1 HAS EXACTLY ONE WIN PLATE, in Stages.Stage9, and that is a change
--     too. Config.Main.StageWins still lists a value for all nine stages, but a
--     scan after streaming every checkpoint in found one NormalWin in the whole
--     world. Do not aim at Stage1-8, there is nothing there to touch.
--   * The plate is NOT gated by level or by wins. It IS gated by world:
--     World2's +1T plate credited exactly 0 while Data.World was 1.
--   * XP is +1 * upgradeMulti every 0.25s while the humanoid is moving.
--     Sampled at multi 1: one award every 0.25s, dead on.
--   * Pinning and moving at the same time works. hum:Move() every Heartbeat while
--     the CFrame is held on the plate credited BOTH: +1.8M wins and level 23 -> 33
--     in the same 10 seconds. That is why there is one loop here, not two phases.
--   * SelectUpgrade(n) works from anywhere, spends nothing, and the unlock is
--     permanent (Data.UnlockedUpgrades gains the entry). Wins are a threshold.
--   * Rebirth() resets Level and Xp to 0 and keeps wins, upgrades and selection.
--   * BuyCharm takes ONE argument, the shop SLOT (1-3), not a world name - the
--     game's own shop panel fires BuyCharm:FireServer(slot). It charges the
--     charm's wins price, verified by the balance moving.
--   * EquipBestCharms WANTS THE TYPE: "Speed" or "Wins". Fired bare it does
--     nothing whatsoever - measured 2026-08-20, eleven owned charms and not one
--     slot moved. See equipCharms().
--   * CollectShard(1..9) is FREE and NOT position gated - all nine Sunken Shards
--     were banked from the World2 spawn, ~2,500 studs away. One time only.
--
-- Never touched, all Robux: the Golden/Diamond/Galaxy/Void/Celestial treadmills,
-- every Aura and every Trail (the whole lists are DevProducts), Speed Multi,
-- Server Speed, Skip Rebirth, Skip Stages, Teleport, Revive, Skull Chest, x2 Wins
-- and the charm-rarity rolls. The panel cannot reach any of them.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local plr = Players.LocalPlayer
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local BigNum = require(ReplicatedStorage.Util.BigNum)
local CfgMain = require(ReplicatedStorage.Config.Main)
local CfgUpgrades = require(ReplicatedStorage.Config.Upgrades)
local CfgCharms = require(ReplicatedStorage.Config.Charms)
local CfgCodes = require(ReplicatedStorage.Config.Codes)
local CfgTrails = require(ReplicatedStorage.Config.Trails)
local CfgAuras = require(ReplicatedStorage.Config.Auras)
local CfgPotions = require(ReplicatedStorage.Config.Potions)

--------------------------------------------------------------------------------
-- config / state
--------------------------------------------------------------------------------

local CONFIG = {
	auto = false,          -- master switch, drives the pin loop
	farmWins = true,       -- hold the character on the win plate
	gainXp = true,         -- hum:Move every frame so the speed award ticks
	autoRebirth = true,
	autoUpgrade = true,
	autoCharms = true,
	autoTrail = true,      -- trails cost WINS and multiply the speed award
	autoAura = true,       -- so do auras, and the two stack
	autoWorld = true,      -- move up a world as soon as the rebirths allow it
	autoFree = true,       -- free reward / offline earnings / streak
	autoPotion = true,     -- drink Speed potions now, hold Wins potions for the next world
	potionHold = 0.5,      -- hold a Wins potion once this share of the next world's rebirths is banked
	autoShards = true,     -- the nine Sunken Shards, once, from anywhere
	stage = 0,             -- 0 = highest stage of the current world
	charmReserve = 2,      -- keep balance >= reserve x the next upgrade threshold
	charmFocus = "auto",   -- "auto" | "Speed" | "Wins", see equipCharms()
}

local STATE = {
	note = "idle",
	target = nil,          -- Vector3 the pin writes every Heartbeat
	targetName = "-",
	stage = 0,
	world = 1,
	wins = 0,
	level = 0,
	rebirths = 0,
	winsRate = 0,
	rateRef = nil,         -- wins at the start of the current rate window
	rateAt = nil,          -- os.clock of that sample
	lastWins = 0,
	lastWinsAt = 0,
	uiOwner = nil,
	charmsBought = 0,
	charmFocus = "-",      -- what equipCharms() last asked the server for
	shards = 0,            -- Sunken Shards banked (max 9, permanent)
	entering = false,      -- true while the body is being walked into a new world
	blocked = nil,         -- set when the server refused something, kept visible
	stalls = 0,            -- how often the watchdog had to rebuild the target
	stallRef = 0,          -- highest wins seen; growth past it means the farm lives
	stallAt = 0,           -- os.clock of the last growth
}

-- Re-executing does not restart the Lua VM, so the previous run's pin and loops
-- are still alive. Every loop captures this and exits when it stops matching.
_G.__MONKEY = (_G.__MONKEY or 0) + 1
local GEN = _G.__MONKEY

--------------------------------------------------------------------------------
-- reading the server's view
--------------------------------------------------------------------------------

local function num(folder)
	local ok, value = pcall(function() return BigNum.ToNumber(BigNum.Get(folder)) end)
	return ok and value or 0
end

local function wins() return num(plr.Data.Wins) end
local function xp() return num(plr.Data.Xp) end
local function level() return plr.Data.Level.Value end
local function rebirths() return plr.Data.Rebirths.Value end
local function world() return plr.Data.World.Value end

local function short(n)
	if type(n) ~= "number" then return "?" end
	local units = { "", "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", "Dc" }
	local i = 1
	while n >= 1000 and i < #units do n = n / 1000 i = i + 1 end
	if i == 1 then return string.format("%d", n) end
	return string.format("%.2f%s", n, units[i])
end

local function char()
	local c = plr.Character
	if not c then return nil end
	return c, c:FindFirstChild("HumanoidRootPart"), c:FindFirstChildOfClass("Humanoid")
end

--------------------------------------------------------------------------------
-- the map
--------------------------------------------------------------------------------

-- Checkpoints are the only part of the map that is always there. Everything else
-- streams (Workspace.StreamingEnabled is true), which is why a win plate three
-- stages away simply does not exist until the character is standing near it.
local function checkpoint(w, stage)
	local folder = Workspace.Map:FindFirstChild("Checkpoints")
	folder = folder and folder:FindFirstChild("World" .. w)
	local cp = folder and folder:FindFirstChild("Checkpoint" .. stage)
	local spawnPoint = cp and cp:FindFirstChild("SpawnPoint")
	if spawnPoint then return spawnPoint.Position + Vector3.new(0, 5, 0) end
	return nil
end

-- The win plate is a Model called NormalWin with a Button part. On World2 it sits
-- one level deeper, inside Stage9.FinalDestination, so this searches descendants.
-- VipWin is the gamepass twin and is never returned.
local function plateIn(container)
	for _, d in ipairs(container:GetDescendants()) do
		if d.Name == "NormalWin" then
			local button = d:FindFirstChild("Button")
			if button and button:IsA("BasePart") then return button end
		end
	end
	return nil
end

-- WHERE the plate is parented is not reliable, and that is the whole bug behind
-- "the monkey stands NEXT to the finish on the higher worlds". Measured on World3:
-- the last plate - the one right beside the portal that reads "World 4, 24 Rebirths
-- Required" - has its Button at (-8077, 279, 2741) and is filed under
-- Stages.Stage7, while the checkpoint beside it is Checkpoint9 at (-8087, 288,
-- 2775). So Stage9 holds no NormalWin at all, the lookup returned nil, the code
-- fell back to the checkpoint and parked the body 36 studs off the plate - close
-- enough to look right on screen and paying exactly nothing.
-- World4 files its plate in Stage9 as expected, so both layouts have to work:
-- the stage folder first, and when it is empty the nearest plate to where the
-- stage ends (a stage's plate sits at its END, i.e. next to the following
-- checkpoint - the last stage has none, so its own checkpoint is the anchor).
local PLATE_SEARCH_RADIUS = 250

local function winPlate(w, stage)
	local worldFolder = Workspace.Map:FindFirstChild("World" .. w)
	local stages = worldFolder and worldFolder:FindFirstChild("Stages")
	if not stages then return nil end
	local stageFolder = stages:FindFirstChild("Stage" .. stage)
	local button = stageFolder and plateIn(stageFolder)
	if button then return button end
	local anchor = checkpoint(w, stage + 1) or checkpoint(w, stage)
	if not anchor then return nil end
	local best, bestDist
	for _, d in ipairs(stages:GetDescendants()) do
		if d.Name == "NormalWin" then
			local b = d:FindFirstChild("Button")
			if b and b:IsA("BasePart") then
				local dist = (b.Position - anchor).Magnitude
				if dist <= PLATE_SEARCH_RADIUS and (not bestDist or dist < bestDist) then
					best, bestDist = b, dist
				end
			end
		end
	end
	return best
end

local function highestStage(w)
	if CONFIG.stage > 0 then return CONFIG.stage end
	-- Stage 9 always exists in every built world; nothing here has to guess.
	for stage = 9, 1, -1 do
		if checkpoint(w, stage) then return stage end
	end
	return 1
end

--------------------------------------------------------------------------------
-- the pin
--------------------------------------------------------------------------------

-- One connection does the whole farm: hold the body on the target and keep the
-- humanoid in a moving state. Both halves are needed - the plate pays on Touched,
-- the speed award only ticks while the humanoid is moving.
local pinConn
local function startPin()
	if pinConn then pinConn:Disconnect() end
	pinConn = RunService.Heartbeat:Connect(function()
		if GEN ~= _G.__MONKEY then pinConn:Disconnect() return end
		if not CONFIG.auto then return end
		local _, hrp, hum = char()
		if CONFIG.farmWins and hrp and STATE.target then
			-- Do NOT zero the velocity here. The original reason was that Touched
			-- only fires again once the parts separate, and letting hum:Move keep
			-- pushing gave that. Re-measured 2026-08-20 the movement no longer
			-- changes anything - the plate is on a flat ~13s server cooldown and
			-- paid at 13.1s with hum:Move and at 13.1s without it - but zeroing the
			-- velocity is still wrong, and hum:Move is what the XP award needs.
			hrp.CFrame = CFrame.new(STATE.target)
		end
		if CONFIG.gainXp and hum then
			hum:Move(Vector3.new(0, 0, 1), false)
		end
	end)
end

--------------------------------------------------------------------------------
-- actions
--------------------------------------------------------------------------------

local function withUI(name, fn)
	if STATE.uiOwner then return false end
	STATE.uiOwner = name
	local ok, err = pcall(fn)
	STATE.uiOwner = nil
	if not ok then STATE.note = name .. " failed: " .. tostring(err) end
	return ok
end

-- Resolves where the body should be. While the plate has not streamed in yet the
-- target is the checkpoint next to it, which is what makes it stream.
local function retarget()
	-- While tryWorld is walking the body into the next world's spawn, Data.World
	-- still reads the old world, so a plain retarget would drag it straight back
	-- to the stage it came from and the switch would never finish.
	if STATE.entering then return false end
	local w = world()
	STATE.world = w
	local stage = highestStage(w)
	STATE.stage = stage
	local button = winPlate(w, stage)
	if button then
		STATE.target = button.Position + Vector3.new(0, 4, 0)
		STATE.targetName = "W" .. w .. " Stage" .. stage .. " win"
		return true
	end
	local cp = checkpoint(w, stage)
	if cp then
		pcall(function() plr:RequestStreamAroundAsync(cp) end)
		STATE.target = cp
		STATE.targetName = "W" .. w .. " CP" .. stage .. " (streaming)"
	end
	return false
end

-- The upgrade ladder is a REQUIREMENT on the balance, never a cost - selecting
-- one spends nothing and the unlock is written into Data.UnlockedUpgrades and
-- stays there. So the pick is the better of "what the balance covers right now"
-- and "what was already unlocked", otherwise spending wins on a trail would
-- silently demote the monkey back down the ladder.
local function unlockedUpgrade()
	local best = 0
	for _, entry in ipairs(plr.Data.UnlockedUpgrades:GetChildren()) do
		local i = tonumber(entry.Name)
		if i and i > best then best = i end
	end
	return best
end

local function bestUpgrade(balance)
	local best = 1
	for i = 1, #CfgUpgrades do
		local entry = CfgUpgrades[i]
		if entry and balance >= (entry.WinsRequirement or math.huge) then best = i end
	end
	return math.max(best, unlockedUpgrade())
end

local function applyUpgrade()
	if not CONFIG.autoUpgrade then return end
	local best = bestUpgrade(STATE.wins)
	if best ~= plr.Data.SelectedUpgrade.Value then
		Remotes.SelectUpgrade:FireServer(best)
		local entry = CfgUpgrades[best]
		STATE.note = "upgrade " .. best .. " (" .. tostring(entry and entry.Skin) ..
			", x" .. short(entry and entry.Multi or 0) .. ")"
	end
end

local function tryRebirth()
	if not CONFIG.autoRebirth then return end
	local need = CfgMain.RebirthLevels[rebirths() + 1]
	if need and level() >= need then
		Remotes.Rebirth:FireServer()
		STATE.note = "rebirth " .. (rebirths() + 1) .. " at level " .. need
	end
end

-- The world gate is real and server side: World2's +1T plate credited exactly
-- nothing while Data.World was 1. WorldRebirthsRequired is the condition.
--
-- There is no remote for the switch. Remotes.TeleportWorld(2) left Data.World at
-- 1 with 8 rebirths banked, and the client's own TeleportController turned out to
-- be the Robux stage-skip (SetTeleportTarget + PromptProduct), so it is not the
-- lever either. What does it: standing in the world's spawn. Warping onto
-- Map.Spawns.SpawnLocation2 flipped Data.World 1 -> 2 within five seconds.
local function desiredWorld()
	local best, reb = 1, rebirths()
	for w = 2, 5 do
		local need = CfgMain.WorldRebirthsRequired["World" .. w]
		if need and reb >= need then best = w end
	end
	return best
end

local function tryWorld()
	if not CONFIG.autoWorld then return end
	local want = desiredWorld()
	if world() == want then return end
	local spawnPoint = Workspace.Map.Spawns:FindFirstChild("SpawnLocation" .. want)
	if not spawnPoint then
		STATE.blocked = "no SpawnLocation" .. want
		return
	end
	local point = spawnPoint.Position + Vector3.new(0, 5, 0)
	pcall(function() plr:RequestStreamAroundAsync(point) end)
	STATE.entering = true
	STATE.target = point
	STATE.targetName = "W" .. want .. " spawn (entering)"
	STATE.note = "entering world " .. want
	for _ = 1, 12 do
		task.wait(1)
		if world() == want then
			STATE.note = "world " .. want .. " at " .. rebirths() .. " rebirths"
			STATE.blocked = nil
			STATE.entering = false
			retarget()
			return
		end
	end
	STATE.entering = false
	STATE.blocked = "spawn" .. want .. " did not set Data.World"
end

-- Wins are spent on three things, all of them permanent unlocks that multiply the
-- speed award: trails (x1.5 Red at 1K up to x30000 Void), auras (x1.5 Amber at 5K
-- up to x7.5 Void) and charms. Verified: BuyTrail("Red") charged exactly 1,000 and
-- BuyAura("Amber") exactly 5,000, both landed in Data.UnlockedTrails/Auras, and
-- EquipTrail/EquipAura take the same name. The Robux ids in Config.ProductIDs are
-- only the alternative way to pay for the SAME item - the wins path is the one
-- used here and the panel never touches the other.

-- The next upgrade tier is worth more than any single trail or aura (x2 per tier
-- and it costs nothing), so nothing is allowed to spend the balance below it.
local function nextUpgradeThreshold()
	local current = math.max(plr.Data.SelectedUpgrade.Value, unlockedUpgrade())
	local entry = CfgUpgrades[current + 1]
	return entry and entry.WinsRequirement or 0
end

-- ...with the usual escape hatch: a purchase that is trivial next to the balance
-- is never worth blocking, otherwise a 550-win charm waits behind a 75M threshold.
local function canSpend(cost)
	if cost <= STATE.wins * 0.01 then return cost <= STATE.wins end
	return STATE.wins - cost >= nextUpgradeThreshold() * CONFIG.charmReserve
end

local function owned(folder, name)
	return folder:FindFirstChild(name) ~= nil
end

-- Highest Multi that the balance allows and that is not owned yet. Ranked on the
-- multiplier, not on the price: the ladders are ordered the same way but reading
-- the config keeps it honest if the dev reshuffles them.
-- ...and never below what is already worn. The first run bought a Blue trail (x2)
-- for 30K while a Rainbow (x5) was equipped, because "best unowned and affordable"
-- says nothing about whether it is an upgrade at all. Wasted wins, nothing gained.
-- The reserve above is right for a charm, which multiplies nothing, and wrong for
-- a trail. Both halves of this decision multiply the SAME number - the speed award
-- - and both are permanent, while an upgrade tier costs nothing at all and only
-- needs the balance to REACH its threshold. So buying a trail does not lose the
-- tier, it delays it, and when the trail multiplies harder than the tier would the
-- delay is the cheaper half. Measured on the stuck run: Yin Yang x250 equipped,
-- Bloodmoon x750 for 9.72e20 sitting affordable at a 1.76e21 balance, blocked for
-- hours by a 2x reserve on a 2.39e21 threshold that is worth x1.95.
local function upgradeGain()
	local current = math.max(plr.Data.SelectedUpgrade.Value, unlockedUpgrade())
	local a, b = CfgUpgrades[current], CfgUpgrades[current + 1]
	if not (a and b and a.Multi and b.Multi and a.Multi > 0) then return math.huge end
	return b.Multi / a.Multi
end

local function bestBuy(config, ownedFolder, floorMulti)
	local pick, pickMulti = nil, floorMulti or 0
	local gate = upgradeGain()
	for name, entry in pairs(config) do
		if not owned(ownedFolder, name) and entry.Multi > pickMulti then
			local gain = entry.Multi / math.max(floorMulti or 0, 1)
			local affordable = (gain >= gate and entry.Price <= STATE.wins) or canSpend(entry.Price)
			if affordable then pick, pickMulti = name, entry.Multi end
		end
	end
	return pick, pickMulti
end

-- Equipping is separate from owning, and the best owned one is not always the one
-- just bought (a cheaper one can already be equipped from a previous session).
local function bestOwned(config, ownedFolder)
	local pick, pickMulti = nil, 0
	for _, entry in ipairs(ownedFolder:GetChildren()) do
		local cfg = config[entry.Name]
		if cfg and cfg.Multi > pickMulti then pick, pickMulti = entry.Name, cfg.Multi end
	end
	return pick
end

local function currentMulti(config, folder)
	local entry = config[folder.Value]
	return entry and entry.Multi or 0
end

local function buyTrail()
	if not CONFIG.autoTrail then return end
	local pick, multi = bestBuy(CfgTrails, plr.Data.UnlockedTrails,
		currentMulti(CfgTrails, plr.Data.EquippedTrail))
	if pick then
		Remotes.BuyTrail:FireServer(pick)
		STATE.note = "trail " .. pick .. " x" .. multi .. " for " .. short(CfgTrails[pick].Price)
		task.wait(1)
	end
	local wear = bestOwned(CfgTrails, plr.Data.UnlockedTrails)
	if wear and plr.Data.EquippedTrail.Value ~= wear then Remotes.EquipTrail:FireServer(wear) end
end

local function buyAura()
	if not CONFIG.autoAura then return end
	local pick, multi = bestBuy(CfgAuras, plr.Data.UnlockedAuras,
		currentMulti(CfgAuras, plr.Data.EquippedAura))
	if pick then
		Remotes.BuyAura:FireServer(pick)
		STATE.note = "aura " .. pick .. " x" .. multi .. " for " .. short(CfgAuras[pick].Price)
		task.wait(1)
	end
	local wear = bestOwned(CfgAuras, plr.Data.UnlockedAuras)
	if wear and plr.Data.EquippedAura.Value ~= wear then Remotes.EquipAura:FireServer(wear) end
end

-- BuyCharm takes ONE argument, the slot number. ("World1", slot) is silently
-- ignored - it flipped no Bought flag and charged nothing, which read exactly like
-- a shop that had run out. A bought charm is auto-equipped, so Data.Charms holding
-- zero entries does not mean the purchase failed; read Data.EquippedCharms too.
-- EquipBestCharms WANTS THE CHARM TYPE. Fired bare - which is what this file did
-- until 2026-08-20 - the server does nothing at all: measured, EquippedCharms sat
-- on Wind Feather / Jungle Gem / Banana Peel across the whole call and did not
-- move a slot, while eleven better charms were owned and unequipped. The game's
-- own panel has two buttons and they send the string:
--   EquipBestCharms:FireServer("Speed")  ->  Lava Lightning Bolt / Rocket Ember x2
--   EquipBestCharms:FireServer("Wins")   ->  Magma Crystal x2 / Hot Coal
-- Three slots, shared between both types, so it is one or the other, never both.
--
-- Which one is right depends on what is actually the bottleneck. Speed is XP is
-- levels is rebirths is the NEXT WORLD, and a world is worth millions of times
-- more per touch than any multiplier (World1 Stage9 pays 400K, World2 Stage9 pays
-- 3.5T). So while a higher world is still out of reach on rebirths, Speed wins by
-- a distance. Once the last world is reached there is nothing left to unlock and
-- the slots go to Wins, which is what buys the trail and aura ladders.
local function equipCharms()
	local want = CONFIG.charmFocus
	if want ~= "Speed" and want ~= "Wins" then
		local w = world()
		local nextWorld = math.min(w + 1, 5)
		local need = CfgMain.WorldRebirthsRequired["World" .. nextWorld]
		want = (nextWorld > w and need and rebirths() < need) and "Speed" or "Wins"
	end
	STATE.charmFocus = want
	Remotes.EquipBestCharms:FireServer(want)
end

local function buyCharms()
	if not CONFIG.autoCharms then return end
	local w = world()
	local shop = plr.Data.CharmShop:FindFirstChild("World" .. w)
	local items = CfgCharms.Items["World" .. w]
	if not shop or not items then return end
	for slot = 1, 3 do
		local bought = shop:FindFirstChild("Bought" .. slot)
		local name = shop:FindFirstChild("Slot" .. slot)
		if bought and name and bought.Value == false then
			local entry = items[name.Value]
			local price = entry and entry.Price or math.huge
			if canSpend(price) then
				Remotes.BuyCharm:FireServer(slot)
				STATE.charmsBought = STATE.charmsBought + 1
				STATE.note = "charm " .. name.Value .. " for " .. short(price)
				task.wait(0.8)
			end
		end
	end
	equipCharms()
end

-- The nine Sunken Shards are a one-time, permanent, free collectible, and
-- CollectShard is NOT position gated: measured 2026-08-20, all nine were banked
-- while the body stood at the World2 spawn, roughly 2,500 studs from the nearest
-- one, and Data.CollectedShards went from empty to 1..9. The models stay in the
-- workspace afterwards - the client normally destroys them on touch and we never
-- touch them - so the workspace is NOT the progress signal. Data.CollectedShards
-- is. Without that distinction this loop would re-fire nine times forever.
local function collectShards()
	if not CONFIG.autoShards then return end
	local folder = Workspace:FindFirstChild("SunkenShards")
	local done = plr.Data:FindFirstChild("CollectedShards")
	if not folder or not done then return end
	STATE.shards = #done:GetChildren()
	if STATE.shards >= 9 then return end
	local got = 0
	for n = 1, 9 do
		if not done:FindFirstChild(tostring(n)) then
			Remotes.CollectShard:FireServer(n)
			got = got + 1
			task.wait(0.4)
		end
	end
	task.wait(1)
	STATE.shards = #done:GetChildren()
	if got > 0 then
		STATE.note = "shards " .. STATE.shards .. "/9"
	end
end

-- Potions were sitting unused for a whole session: five of them in Data.Potions
-- with Data.ActivePotions empty. Verified: Remotes.UsePotion:FireServer(name)
-- takes the plain inventory name, consumed one ("Speed Potion (10m)" 1 -> 0) and
-- put "x2 Speed = 598" into ActivePotions, so the value there is seconds left.
--
-- They are used at different times on purpose. A Speed potion doubles the XP
-- award, and XP is what the run is actually short of - levels make rebirths and
-- rebirths are the ONLY gate on the next world - so it burns immediately. A Wins
-- potion doubles a number that is worth a thousand times more one world up
-- (World3 stage 9 pays 4e17, World4 stage 9 pays 1e24), so it waits until there
-- is no world left to unlock.
local function usePotions()
	if not CONFIG.autoPotion then return end
	local active = {}
	for _, c in ipairs(plr.Data.ActivePotions:GetChildren()) do active[c.Name] = true end
	-- "hold until the world is unlocked" is not enough on its own: the world after
	-- this one is not unlockable yet either, so the bottle gets drunk minutes before
	-- the switch that makes it worth a million times more. Hold it while the next
	-- world is genuinely in reach - measured here at 19 of the 24 rebirths it wants.
	local nextNeed = CfgMain.WorldRebirthsRequired["World" .. (world() + 1)]
	local holdWins = world() ~= desiredWorld()
		or (nextNeed and rebirths() >= nextNeed * CONFIG.potionHold) or false
	for _, entry in ipairs(plr.Data.Potions:GetChildren()) do
		local cfg = CfgPotions.ByName and CfgPotions.ByName[entry.Name]
		local category = cfg and cfg.Category or (entry.Name:find("Wins") and "Wins" or "Speed")
		local buff = cfg and cfg.BuffName or ("x2 " .. category)
		if entry.Value > 0 and not active[buff] and not (category == "Wins" and holdWins) then
			Remotes.UsePotion:FireServer(entry.Name)
			active[buff] = true
			STATE.note = "potion " .. entry.Name
			task.wait(0.5)
		end
	end
end

local function claimFree()
	if not CONFIG.autoFree then return end
	if plr:GetAttribute("HasOfflineReward") then
		Remotes.ClaimOfflineEarnings:FireServer()
	end
	if plr.Data.ClaimedFreeReward.Value == false then
		Remotes.ClaimFreeReward:FireServer()
	end
	Remotes.ClaimStreakReward:FireServer()
end

-- Every active code needs group membership: all six answered "not_in_group".
-- Kept as a button rather than a loop so the refusal is visible once.
local function redeemCodes()
	-- Counted rather than concatenated: six "CODE already_redeemed" pairs make one
	-- line far longer than the read-out can show, and the interesting part (did any
	-- of them pay out) then falls off the right edge.
	local tally, first = {}, nil
	for _, code in ipairs(CfgCodes.Active) do
		local ok, res = pcall(function() return Remotes.RedeemCode:InvokeServer(code) end)
		local answer = tostring(ok and res or "error")
		tally[answer] = (tally[answer] or 0) + 1
		if answer ~= "already_redeemed" and not first then first = code .. " " .. answer end
		task.wait(0.5)
	end
	local parts = {}
	for answer, count in pairs(tally) do parts[#parts + 1] = count .. "x " .. answer end
	STATE.note = "codes: " .. table.concat(parts, ", ") .. (first and ("  (" .. first .. ")") or "")
end

local function unstuck()
	local c, hrp, hum = char()
	CONFIG.auto = false
	if hrp then
		hrp.Anchored = false
		hrp.AssemblyLinearVelocity = Vector3.zero
	end
	if hum then
		hum.PlatformStand = false
		hum:ChangeState(Enum.HumanoidStateType.GettingUp)
	end
	local cp = checkpoint(world(), 1)
	if hrp and cp then hrp.CFrame = CFrame.new(cp) end
	STATE.note = "unstuck, auto off"
end

--------------------------------------------------------------------------------
-- watchdog
--------------------------------------------------------------------------------

-- Meant for unattended runs. Everything here recovers from something that was
-- actually seen going wrong: the body drifting off the plate after a respawn, a
-- rebirth or a world switch leaving the old target behind, and a stage whose
-- plate had not streamed in yet when retarget last looked. The rule is the same
-- one the rest of this file uses - a server value has to move, so the trigger is
-- the wins balance standing still, never a counter this script keeps itself.
local STALL_SECONDS = 90

-- Wider than the plate's ~13s cooldown, or the header rate reads 0/s forever.
local RATE_WINDOW = 30

local function watchdog(now)
	if not CONFIG.auto then
		STATE.stallAt = now
		return
	end
	-- offline earnings and rebirths both move the balance, so growth is the honest
	-- signal that the farm is alive.
	if STATE.wins > (STATE.stallRef or 0) then
		STATE.stallRef, STATE.stallAt = STATE.wins, now
		return
	end
	STATE.stallAt = STATE.stallAt or now
	if STATE.entering then return end
	if now - STATE.stallAt < STALL_SECONDS then return end

	STATE.stalls = (STATE.stalls or 0) + 1
	STATE.stallAt = now
	-- Drop the target and rebuild it from the checkpoint, which is the only part
	-- of the map that is always loaded, then let retarget upgrade to the plate
	-- once it has streamed in.
	STATE.target = nil
	STATE.targetName = "-"
	STATE.blocked = nil
	local cp = checkpoint(world(), highestStage(world()))
	if cp then
		pcall(function() plr:RequestStreamAroundAsync(cp) end)
		STATE.target = cp
	end
	local _, hrp, hum = char()
	if hrp then hrp.Anchored = false end
	if hum then hum.PlatformStand = false end
	retarget()
	STATE.note = "stall " .. STATE.stalls .. ": re-targeted " .. tostring(STATE.targetName)
end

--------------------------------------------------------------------------------
-- loops
--------------------------------------------------------------------------------

local function loop(interval, key, fn)
	task.spawn(function()
		while GEN == _G.__MONKEY do
			if CONFIG.auto and (key == nil or CONFIG[key]) then
				local ok, err = pcall(fn)
				if not ok then STATE.note = tostring(err) end
			end
			task.wait(interval)
		end
	end)
end

-- fast: keep the target honest and take every rebirth the moment it is available
loop(1, nil, function()
	STATE.wins = wins()
	STATE.level = level()
	STATE.rebirths = rebirths()
	local now = os.clock()
	-- The rate has to be measured over a window WIDER than the plate's cooldown.
	-- This loop ticks once a second and the plate pays once every ~13, so a
	-- tick-to-tick rate reads 0/s on twelve ticks out of thirteen and the header
	-- said "0/s" while the balance was climbing perfectly well. A 30s window
	-- covers at least two payouts and reads the truth.
	if STATE.rateAt == nil or now - STATE.rateAt >= RATE_WINDOW then
		if STATE.rateAt and now > STATE.rateAt then
			local rate = (STATE.wins - (STATE.rateRef or STATE.wins)) / (now - STATE.rateAt)
			if rate >= 0 then STATE.winsRate = rate end
		end
		STATE.rateRef, STATE.rateAt = STATE.wins, now
	end
	STATE.lastWins, STATE.lastWinsAt = STATE.wins, now
	retarget()
	tryRebirth()
	applyUpgrade()
	watchdog(now)
end)

-- slow: the things that only change every so often
loop(15, nil, function()
	tryWorld()
	buyTrail()
	buyAura()
	buyCharms()
	collectShards()
	usePotions()
	claimFree()
end)

--------------------------------------------------------------------------------
-- panel
--------------------------------------------------------------------------------

local UI = (_G.__SEL and _G.__SEL.ui) or loadstring(readfile("ui-template.lua"))()

if _G.__MONKEY_WIN then pcall(function() _G.__MONKEY_WIN:Destroy() end) end

local win = UI.Window({
	title = "SPEED", accentTitle = "MONKEY", subtitle = "seltonmt",
	badge = "🐒", width = 920, height = 580,
})
_G.__MONKEY_WIN = win

local farm = win:Page("FARM", UI.icon.bolt)

local main = farm:Card("LOOP", 1)
main:Toggle("AUTO", CONFIG.auto, function(v)
	CONFIG.auto = v
	STATE.note = v and "running" or "stopped"
end, "holds the body on the win plate and keeps it moving", UI.theme.good)
main:Toggle("Farm wins", CONFIG.farmWins, function(v) CONFIG.farmWins = v end,
	"pin on NormalWin.Button, ~13s server cooldown per touch")
main:Toggle("Gain XP", CONFIG.gainXp, function(v) CONFIG.gainXp = v end,
	"hum:Move each frame, +1 x upgrade multi per 0.25s")
main:Stepper("Stage", function()
	return CONFIG.stage == 0 and "Auto" or ("Stage " .. CONFIG.stage)
end, function(dir)
	CONFIG.stage = math.clamp(CONFIG.stage + dir, 0, 9)
end, "0 = highest stage of the current world")

local prog = farm:Card("PROGRESSION", 2)
prog:Toggle("Auto rebirth", CONFIG.autoRebirth, function(v) CONFIG.autoRebirth = v end,
	"level ladder 15 / 25 / 40 ... 625, keeps wins and upgrades", UI.theme.warn)
prog:Toggle("Auto upgrade", CONFIG.autoUpgrade, function(v) CONFIG.autoUpgrade = v end,
	"SelectUpgrade to the best the wins balance allows, costs nothing")
prog:Toggle("Auto world", CONFIG.autoWorld, function(v) CONFIG.autoWorld = v end,
	"World2 at 8 rebirths, then 16 / 24 / 32", UI.theme.warn)

local spend = farm:Card("WINS SPENDING", 1)
spend:Toggle("Auto trail", CONFIG.autoTrail, function(v) CONFIG.autoTrail = v end,
	"Red x1.5 @1K ... Void x30000, paid in wins", UI.theme.warn)
spend:Toggle("Auto aura", CONFIG.autoAura, function(v) CONFIG.autoAura = v end,
	"Amber x1.5 @5K ... Void x7.5, stacks with the trail", UI.theme.warn)
spend:Toggle("Auto charms", CONFIG.autoCharms, function(v) CONFIG.autoCharms = v end,
	"3 rolled slots per world, restock every 300s", UI.theme.warn)
spend:Dropdown("Charm slots", { "auto", "Speed", "Wins" }, CONFIG.charmFocus, function(v)
	CONFIG.charmFocus = v
	task.spawn(equipCharms)
end)
spend:Label("auto = Speed until the next world is reachable, then Wins")
spend:Stepper("Upgrade reserve", function() return CONFIG.charmReserve .. "x" end,
	function(dir) CONFIG.charmReserve = math.clamp(CONFIG.charmReserve + dir, 0, 10) end,
	"never spend below this multiple of the next upgrade threshold")

local extra = farm:Card("EXTRAS", 2)
extra:Toggle("Claim free rewards", CONFIG.autoFree, function(v) CONFIG.autoFree = v end,
	"offline earnings, playtime reward, streak")
extra:Toggle("Drink potions", CONFIG.autoPotion, function(v) CONFIG.autoPotion = v end,
	"speed now, wins held back until the last world is reached", UI.theme.warn)
extra:Toggle("Collect shards", CONFIG.autoShards, function(v) CONFIG.autoShards = v end,
	"the nine Sunken Shards, free, once, from anywhere - no walking")
extra:Button("Redeem codes", function() task.spawn(redeemCodes) end)
extra:Label("codes need the group - all six answer not_in_group")
extra:Button("Unstuck", unstuck, UI.theme.bad)
extra:Label("no Robux path exists in this panel")

local out = farm:Card("STATUS", 0):Readout(14, function(text)
	if text:find("blocked") then return UI.theme.bad end
	if text:find("^AUTO") then return UI.theme.good end
	return nil
end)

task.spawn(function()
	while GEN == _G.__MONKEY do
		local entry = CfgUpgrades[plr.Data.SelectedUpgrade.Value] or {}
		local needReb = CfgMain.RebirthLevels[STATE.rebirths + 1]
		local needWorld = CfgMain.WorldRebirthsRequired["World" .. (STATE.world + 1)]
		local lines = {
			CONFIG.auto and "AUTO RUNNING" or "STOPPED",
			"  target   " .. tostring(STATE.targetName),
			"  wins     " .. short(STATE.wins) .. "   " .. short(STATE.winsRate) .. "/s",
			"  level    " .. STATE.level .. (needReb and ("  -> rebirth at " .. needReb) or ""),
			"  rebirth  " .. STATE.rebirths ..
				(needWorld and ("  -> world " .. (STATE.world + 1) .. " at " .. needWorld) or ""),
			"  upgrade  " .. plr.Data.SelectedUpgrade.Value .. " " .. tostring(entry.Skin) ..
				"  x" .. short(entry.Multi or 0),
			"  trail    " .. (plr.Data.EquippedTrail.Value ~= "" and
				(plr.Data.EquippedTrail.Value .. " x" ..
				 tostring((CfgTrails[plr.Data.EquippedTrail.Value] or {}).Multi)) or "none"),
			"  aura     " .. (plr.Data.EquippedAura.Value ~= "" and
				(plr.Data.EquippedAura.Value .. " x" ..
				 tostring((CfgAuras[plr.Data.EquippedAura.Value] or {}).Multi)) or "none"),
			"  charms   " .. STATE.charmsBought .. " bought, slots on " .. STATE.charmFocus,
			"  shards   " .. STATE.shards .. "/9",
			"  watchdog " .. STATE.stalls .. " stalls, last growth " ..
				string.format("%.0fs ago", math.max(0, os.clock() - (STATE.stallAt or 0))),
			"  " .. tostring(STATE.note),
		}
		if STATE.blocked then lines[#lines + 1] = "  blocked  " .. STATE.blocked end
		pcall(function() out:set(lines) end)
		pcall(function()
			win:SetStatus(string.format("%s wins   lvl %d   reb %d   world %d   %s",
				short(STATE.wins), STATE.level, STATE.rebirths, STATE.world, STATE.targetName))
		end)
		task.wait(0.5)
	end
end)

-- The Home tab: the GitHub commit log as the changelog, plus what this run is
-- doing. Declared last but the template moves it to the front of the rail, so it
-- is always the first icon and the page the panel opens on.
pcall(function() win:Home() end)

-- The three numbers in the header strip, and the master switch wired to AUTO so
-- the strip's toggle is not a decoration.
win:SetStat(1, "-", "wins")
win:SetStat(2, "-", "rate")
win:SetStat(3, "-", "rebirths")
win:SetMaster(CONFIG.auto, CONFIG.auto and "Auto Farm laeuft" or "Gestoppt")
win:OnMaster(function(on)
	CONFIG.auto = on
	STATE.note = on and "running" or "stopped"
	win:Refresh()
end)
task.spawn(function()
	while GEN == _G.__MONKEY do
		pcall(function()
			win:SetStat(1, short(STATE.wins))
			win:SetStat(2, short(STATE.winsRate) .. "/s")
			win:SetStat(3, tostring(STATE.rebirths))
			-- Kein Untertitel hier. Die Zeile darunter gehoert SetStatus, das sie
			-- im Read-out-Loop mit den Zahlen fuellt - beide zu schreiben liess
			-- sie im Sekundentakt zwischen den Zahlen und "Ziel ..." springen.
			win:SetMaster(CONFIG.auto, CONFIG.auto and "Auto Farm laeuft" or "Gestoppt")
		end)
		task.wait(1)
	end
end)

win:Refresh()
startPin()

--------------------------------------------------------------------------------

_G.__MONKEY_DBG = {
	CONFIG = CONFIG, STATE = STATE,
	retarget = retarget, applyUpgrade = applyUpgrade, tryRebirth = tryRebirth,
	tryWorld = tryWorld, buyCharms = buyCharms, claimFree = claimFree,
	buyTrail = buyTrail, buyAura = buyAura, canSpend = canSpend,
	usePotions = usePotions, upgradeGain = upgradeGain, desiredWorld = desiredWorld,
	unlockedUpgrade = unlockedUpgrade, nextUpgradeThreshold = nextUpgradeThreshold,
	redeemCodes = redeemCodes, unstuck = unstuck, watchdog = watchdog,
	equipCharms = equipCharms, collectShards = collectShards,
	wins = wins, xp = xp, level = level, rebirths = rebirths, world = world,
	winPlate = winPlate, checkpoint = checkpoint, bestUpgrade = bestUpgrade,
}

print("[speedmonkey] gen " .. GEN .. " ready - RightShift for the panel")
