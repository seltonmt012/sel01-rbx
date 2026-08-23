--!nocheck
-- [+1 Loot Evo] - farm loop that actually moves server side numbers.
--
-- Everything below was measured live, not assumed:
--
--   * A stage only starts when its StageStartPart receives a Touched event.
--     A plain CFrame teleport does nothing - firetouchinterest does. That was
--     why teleporting in left you standing in an empty stage.
--   * Killing mobs by writing HP through the client controller works visually
--     and even makes the client send LocalMobKilled + LocalStageCleared, but the
--     server discards it: wins, exp and HighestClearedStage never moved. Client
--     side only, worthless. It is kept as an off-by-default toggle, labelled.
--   * What does count: enter the stage properly, let the real damage happen
--     (auto click / swings), then touch WinBut.TouchPart. Verified 12 -> 13 wins.
--   * Weapons are bought and equipped by touching HallWeaponN.TouchPart in
--     Hall.WeaponArea. Verified Weapon3 -> Weapon4, damage 997 -> 2104.
--   * WeaponConfig entries carry VictoryPoint (price in wins) and EXP (power).
--     Robux weapons list VictoryPoint 0 and must be excluded or they look free.
--   * BackPackActionEvent:FireServer("EquipBest", {Kind = "Equip" | "Gem"}).
--   * BuyEggEvent:FireServer() takes no arguments; the server resolves the egg
--     from where you stand, so buying means standing at the egg model.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

local plr = Players.LocalPlayer

local FARM_MODES = { "smart ladder", "repeat cleared", "push next", "fixed stage" }

local CONFIG = {
	autoFarm = false,
	farmMode = 1,          -- index into FARM_MODES
	stage = 1,             -- used by "fixed stage"
	stageTimeout = 35,     -- seconds before a stage counts as too hard; bosses
	                       -- are slow and this is the only thing that demotes now
	spawnTimeout = 5,      -- seconds to wait for the first mob before giving up
	fastSeconds = 5,       -- a clear this quick below the frontier jumps ahead
	farmRuns = 5,          -- runs to bank on the fallback stage before retrying
	autoEggBest = true,    -- buy the strongest egg the wins allow, not a fixed one
	petCopies = 3,         -- copies of an egg's top pet before that egg is done
	autoAura = false,      -- buy + equip the best aura the wins allow
	godMode = false,       -- drop the client's own damage report
	skipDash = true,       -- leave slot 1 alone while it holds the Sprint dash
	chaseMobs = true,      -- close the gap to mobs that run away, bosses mostly
	chaseRange = 9,        -- studs before a reposition happens
	autoSkill = false,     -- buy the cheapest missing skill, then equip it
	castSkills = false,    -- fire equipped skills off cooldown while farming
	cleanPets = false,     -- delete the weakest pets, keep the best petKeep
	cleanBag = false,      -- drive the game's own auto-delete for gear and gems
	deleteRarity = 3,      -- index into RARITIES: 3 = Common, Uncommon, Rare
	petKeep = 12,
	gearKeep = 12,
	gemKeep = 12,
	autoWeapon = false,    -- buy/equip the best weapon the wins allow
	autoEquip = false,     -- EquipBest gear + gems
	autoPet = false,
	autoBuyEgg = false,
	egg = 1,
	autoClick = false,     -- the real damage engine, works anywhere
	clickRate = 20,        -- clicks per second
	autoRebirth = false,   -- fire RebirthRequest once the level requirement is met
}

-- Deliberately removed after testing, do not add back without new evidence:
--   Insta Kill      - client only. Mobs die, LocalStageCleared even fires, but
--                     the server credits nothing: wins/exp/cleared never moved.
--   Auto Swing      - RequestManualSwing outside a live stage leaves
--                     stageSwingBusy set and the movement lock never releases.
--                     That was the "everything frozen" bug. Auto Click replaces
--                     it and is what raises damage anyway.
--   God Mode        - blocking LocalMobHitPlayer never showed a measurable
--                     effect on health; unproven, so it is gone.
--   Float           - cosmetic hover, no measured benefit, and it fought the
--                     stage entry positioning.
--   Auto Rebirth    - destructive and never verified end to end.
--   Auto Skill      - no skills unlocked on this account, so it was a no-op.

local STATE = {
	wins = 0, level = 0, rebirth = 0, damage = 0, cleared = 0, needLevel = 0,
	runs = 0, winsGained = 0, clicks = 0, rebirths = 0, weapon = "-", phase = "idle", note = "-",
	stageNow = "-", mobs = 0, tooHard = {}, unlocked = {}, noSpawn = {},
	deaths = 0,
	missedClaims = 0,
	resetToken = 0,
	primed = false,
	auras = 0,
	eggsBought = 0,
	peakDamage = 0,
	codesDone = false,
	deleted = 0,
	autoDeleteSet = -1,
	skillsBought = 0,
	petsCleanedAt = -1,
	casts = 0,
	chases = 0,
	healed = 0,
	uiOwner = "-",
	lastLevel = 0,
	ladder = 1,            -- stage the smart mode is currently working on
	lastClear = 0,         -- seconds the last successful run took
	bankRuns = 0,          -- runs already banked on the fallback stage
	blockedAt = 0,         -- ladder value that failed, 0 when nothing failed
}

_G.__LOOTEVO = (_G.__LOOTEVO or 0) + 1
local generation = _G.__LOOTEVO
if _G.__LOOTEVO_GUI then pcall(function() _G.__LOOTEVO_GUI:Destroy() end) end
if _G.__LOOTEVO_PAD then pcall(function() _G.__LOOTEVO_PAD:Destroy() end) end

local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
local snapshotRemote = Remotes:WaitForChild("GetPlayerDataSnapshot", 10)
local backpackRemote = Remotes:WaitForChild("BackPackActionEvent", 10)
local rebirthRemote = Remotes:WaitForChild("RebirthRequest", 10)
local buyEggRemote = Remotes:WaitForChild("BuyEggEvent", 10)

local clickRemote = Remotes:WaitForChild("ClickRequest", 10)

local weaponCfg = require(ReplicatedStorage.Config.WeaponConfig)
local eggHelper = require(ReplicatedStorage.Config.EggHelper)

local hall = workspace.Scene.Hall
local stageRoot = workspace.Scene.Stage
local weaponArea = hall:FindFirstChild("WeaponArea")
local eggFolder = hall:FindFirstChild("Egg")

local HALL_POSITION = Vector3.new(319.105, 7.75, -81.22)
local MAX_STAGE = 36

-- Catalogues -----------------------------------------------------------------

local WEAPONS = {}   -- only the wins-purchasable ones, weakest first
for _, entry in pairs(weaponCfg) do
	if type(entry) == "table" and type(entry.ID) == "string" then
		local index = entry.ID:match("^Weapon(%d+)$")
		if index then
			table.insert(WEAPONS, {
				id = entry.ID,
				index = tonumber(index),
				name = entry.Name or entry.ID,
				price = entry.VictoryPoint or 0,
				power = entry.EXP or 0,
			})
		end
	end
end
table.sort(WEAPONS, function(a, b) return a.power < b.power end)

local AURAS = {}
do
	local ok, auraCfg = pcall(require, ReplicatedStorage.Config.AuraConfig)
	if ok and type(auraCfg) == "table" then
		for key, entry in pairs(auraCfg) do
			if type(entry) == "table" and entry.ID then
				table.insert(AURAS, {
					id = entry.ID,
					index = tonumber(key) or tonumber(entry.ID:match("%d+")) or 1,
					name = entry.Name or entry.ID,
					price = entry.Wins or math.huge,
					bonus = entry.WinsBonus or 1,
				})
			end
		end
	end
	table.sort(AURAS, function(a, b) return a.price < b.price end)
end

local EGGS = {}
do
	local ok, all = pcall(eggHelper.GetAllEggs)
	if ok and type(all) == "table" then
		for _, entry in pairs(all) do
			if type(entry) == "table" and entry.ID then
				table.insert(EGGS, { id = entry.ID, name = entry.Name or entry.ID, price = entry.VictoryPoints or 0 })
			end
		end
	end
	table.sort(EGGS, function(a, b) return a.price < b.price end)
	if #EGGS == 0 then EGGS[1] = { id = "NoviceEgg", name = "Grass Egg", price = 400 } end
end

local function shortNumber(n)
	n = tonumber(n) or 0
	for _, u in ipairs({ { 1e12, "T" }, { 1e9, "B" }, { 1e6, "M" }, { 1e3, "K" } }) do
		if n >= u[1] then return string.format("%.1f%s", n / u[1], u[2]) end
	end
	return tostring(math.floor(n))
end

local function rootPart()
	local char = plr.Character
	return char and char:FindFirstChild("HumanoidRootPart")
end

-- Death tracking -------------------------------------------------------------
-- Losing a stage does not time out: the mobs kill you, the character respawns in
-- the hall and the run silently ends. The ladder has to see that as a failure,
-- so a flag is raised on death and read by the farm cycle.

local diedFlag = false

local function watchCharacter(char)
	local hum = char:FindFirstChildOfClass("Humanoid") or char:WaitForChild("Humanoid", 5)
	if not hum then return end
	hum.Died:Connect(function()
		if _G.__LOOTEVO == generation then diedFlag = true end
	end)
end

if plr.Character then watchCharacter(plr.Character) end
plr.CharacterAdded:Connect(function(char)
	if _G.__LOOTEVO ~= generation then return end
	diedFlag = true          -- a respawn during a run means the run was lost
	watchCharacter(char)
end)

local function touch(part)
	local hrp = rootPart()
	if not hrp or not part or not firetouchinterest then return false end
	firetouchinterest(hrp, part, 0)
	task.wait(0.2)
	firetouchinterest(hrp, part, 1)
	return true
end

-- Controller lookup ----------------------------------------------------------
-- getgc is only ~30ms, but it is still done once and cached in _G rather than
-- per loop iteration.

_G.__LOOTEVO_CTRL = _G.__LOOTEVO_CTRL or { stage = nil, skill = nil, lastScan = 0, scanning = false }
local CTRL = _G.__LOOTEVO_CTRL

local function scanControllers()
	if CTRL.scanning or os.clock() - CTRL.lastScan < 20 then return end
	CTRL.scanning = true
	CTRL.lastScan = os.clock()
	task.spawn(function()
		local objects = getgc(true)
		local stageClass, skillClass
		local processed = 0
		for _, t in pairs(objects) do
			if type(t) == "table" and rawget(t, "new") ~= nil then
				if not stageClass and rawget(t, "DamageLocalMobsInRadius") ~= nil then stageClass = t end
				if not skillClass and rawget(t, "GetEquippedSkillIds") ~= nil then skillClass = t end
			end
			processed += 1
			if processed % 500 == 0 then task.wait() end
		end
		processed = 0
		for _, t in pairs(objects) do
			if type(t) == "table" then
				local meta = getmetatable(t)
				if stageClass and meta == stageClass and rawget(t, "attackHitDelays") ~= nil then CTRL.stage = t end
				if skillClass and meta == skillClass and rawget(t, "audio") ~= nil then CTRL.skill = t end
			end
			processed += 1
			if processed % 500 == 0 then task.wait() end
		end
		CTRL.scanning = false
		STATE.note = CTRL.stage and "controllers ready" or "controllers missing"
	end)
end

-- activeLocalStage is nil whenever the player is in the hall, so freshness is
-- checked against a field the controller always carries.
local function stageCtrl()
	local c = CTRL.stage
	if c and rawget(c, "attackHitDelays") ~= nil then return c end
	CTRL.stage = nil
	scanControllers()
	return nil
end

-- God mode -------------------------------------------------------------------
--
-- Damage taken is reported by the client itself: LocalStageController's
-- fireLocalMobHit sends LocalMobHitPlayer:FireServer{Id, Damage}. Two layers,
-- because either alone can be bypassed by the other path:
--   1. the controller method is replaced with a no-op, so nothing is generated
--   2. a namecall hook drops the remote call if something else emits it
-- The hook is installed once per session and only checks a boolean, so it costs
-- nothing while god mode is off.

if not _G.__LOOTEVO_HOOK then
	local original
	original = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
		if _G.__LOOTEVO_BLOCKHIT and getnamecallmethod() == "FireServer" then
			local ok, name = pcall(function() return self.Name end)
			if ok and name == "LocalMobHitPlayer" then return nil end
		end
		return original(self, ...)
	end))
	_G.__LOOTEVO_HOOK = true
end

local function applyGodMode(on)
	_G.__LOOTEVO_BLOCKHIT = on
	local ctrl = CTRL.stage
	if ctrl then
		if on then
			rawset(ctrl, "fireLocalMobHit", function() end)
		else
			rawset(ctrl, "fireLocalMobHit", nil)   -- falls back to the class method
		end
	end
end

-- Third layer, and the only one that is directly observable: the humanoid is
-- pinned to full health every frame. A forged LocalMobHitPlayer payload is
-- ignored by the server, so blocking that remote could not be proven on its own.
local godClamp
task.spawn(function()
	while _G.__LOOTEVO == generation do
		if CONFIG.godMode then
			local char = plr.Character
			local hum = char and char:FindFirstChildOfClass("Humanoid")
			if hum and hum.Health < hum.MaxHealth then
				hum.Health = hum.MaxHealth
				STATE.healed += 1
			end
		end
		task.wait(0.1)
	end
end)

-- Recovery -------------------------------------------------------------------

local function unstuck()
	local ctrl = stageCtrl()
	if ctrl then
		ctrl.stageSwingBusy = false
		ctrl.bufferedStageSwing = false
	end
	pcall(function() require(plr.PlayerScripts.PlayerModule):GetControls():Enable() end)
	local char = plr.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.PlatformStand = false
		hum.AutoRotate = true
		if hum.WalkSpeed < 1 then hum.WalkSpeed = 20 end
		hum:ChangeState(Enum.HumanoidStateType.GettingUp)
		local cam = workspace.CurrentCamera
		cam.CameraType = Enum.CameraType.Custom
		cam.CameraSubject = hum
		plr.CameraMinZoomDistance = 0.5
		plr.CameraMaxZoomDistance = 400
	end
	local hrp = rootPart()
	if hrp then hrp.Anchored = false end
	STATE.note = "unstuck"
end

-- Data -----------------------------------------------------------------------

-- Everything a rebirth invalidates, in one place so the manual button and the
-- automatic detection cannot drift apart. `resetToken` is what stops a farm
-- cycle that was already in flight from writing the old stage back into the
-- ladder a second later - that was why a detected rebirth still looked ignored.
local function resetProgression(reason)
	STATE.ladder = 1
	STATE.blockedAt = 0
	STATE.bankRuns = 0
	STATE.tooHard = {}
	STATE.noSpawn = {}
	STATE.peakDamage = STATE.damage
	STATE.resetToken += 1
	STATE.note = string.format("rebirth %d (%s) -> ladder reset to 1",
		STATE.rebirth, reason or "manual")
end

local function snapshot()
	local ok, data = pcall(function() return snapshotRemote:InvokeServer() end)
	if not ok or type(data) ~= "table" then return nil end
	-- Captured before anything is overwritten: comparing after the assignment
	-- compares the value with itself and the rebirth is never noticed.
	local previousRebirth = STATE.rebirth

	local before = STATE.wins
	STATE.wins = data.VictoryPoints or 0
	STATE.level = data.Level or 0
	STATE.rebirth = data.Rebirth or 0
	STATE.damage = data.Damage or 0
	if STATE.peakDamage < STATE.damage then STATE.peakDamage = STATE.damage end
	STATE.cleared = data.HighestClearedStage or 0
	STATE.needLevel = data.NextRebirthNeedLevel or 0

	STATE.weapon = tostring(data.EquippedWeapon or "-")
	STATE.unlocked = type(data.UnlockedEquipment) == "table" and data.UnlockedEquipment or STATE.unlocked
	-- OwnedAuras may arrive as a list of ids or as an id -> true map.
	if type(data.OwnedAuras) == "table" then
		local owned = {}
		for key, value in pairs(data.OwnedAuras) do
			if type(value) == "string" then owned[value] = true
			elseif value == true then owned[tostring(key)] = true end
		end
		STATE.ownedAuras = owned
	end
	-- Only after the baseline exists. On the first snapshot `before` is 0, so
	-- the whole balance counted as earned this session and the panel reported
	-- 2.3M gained the instant the script loaded.
	if STATE.primed and STATE.wins > before then STATE.winsGained += STATE.wins - before end

	-- Two independent signals, because the counter alone missed rebirths that
	-- happened while the script was reloading: the rebirth number going up, or
	-- the level collapsing (level only ever drops on a rebirth).
	local levelCollapsed = STATE.lastLevel > 3 and STATE.level < STATE.lastLevel
	STATE.lastLevel = STATE.level

	-- The first snapshot after an execute only seeds the baseline. Without this
	-- the fresh STATE (rebirth 0, level 0) against a live account reads as a
	-- rebirth every single reload, which reset the ladder and made real runs
	-- look like they happened "mid rebirth".
	if not STATE.primed then
		STATE.primed = true
	elseif STATE.rebirth > previousRebirth or levelCollapsed then
		resetProgression(levelCollapsed and "level drop" or "counter")
	end

	return data
end

local function aliveMobs()
	local ctrl = stageCtrl()
	local stage = ctrl and ctrl.activeLocalStage
	if not stage or type(stage.Mobs) ~= "table" then return 0 end
	local n = 0
	for _, mob in pairs(stage.Mobs) do
		if type(mob) == "table" and not mob.Dead then n += 1 end
	end
	return n
end

local function activeStageNumber()
	local ctrl = stageCtrl()
	local id = ctrl and ctrl.activeLocalStage and ctrl.activeLocalStage.Id
	return type(id) == "string" and tonumber(id:match("Stage(%d+)")) or nil
end

-- Actions --------------------------------------------------------------------

local function goHall()
	local hrp = rootPart()
	if hrp then hrp.CFrame = CFrame.new(HALL_POSITION) end
end

-- Enter a stage the way the game expects: stand on the pad, then fire its touch.
local function enterStage(number)
	local folder = stageRoot:FindFirstChild("Stage" .. number)
	local pad = folder and folder:FindFirstChild("StageStartPart", true)
	local hrp = rootPart()
	if not pad or not hrp then return false end
	hrp.CFrame = CFrame.new(pad.Position + Vector3.new(0, pad.Size.Y / 2 + 3, 0))
	task.wait(0.4)
	touch(pad)
	return true
end

-- Only the plain WinBut. 2xWinBut is the paid double-reward pad, so it is never
-- touched.
--
-- The pad is identical on every stage, boss or not, but after a long fight it is
-- not ready the instant the last mob dies - the death and reward animations run
-- first, and a single touch fired into that window is simply lost. So the claim
-- is retried until the balance actually moves.
local function claimWin(number)
	local folder = stageRoot:FindFirstChild("Stage" .. number)
	local model = folder and folder:FindFirstChild("WinBut")
	local part = model and model:FindFirstChild("TouchPart")
	if not part then return false end

	local before = STATE.wins
	for attempt = 1, 6 do
		touch(part)
		task.wait(0.7)
		snapshot()
		if STATE.wins > before then
			if attempt > 1 then
				STATE.note = string.format("claimed stage %d on try %d", number, attempt)
			end
			return true
		end
	end

	STATE.note = "claim failed on stage " .. number
	STATE.missedClaims += 1
	return false
end

-- ClickRequest takes no arguments and is what actually raises Damage - it works
-- with no mob in sight. Measured: 10 clicks paced at 0.15s gave +31 damage each,
-- 88 clicks at 0.03s gave +9.7 each, so the server throttles the per-click value
-- but the faster rate still nets more per second (283 vs 206).
local clickBudget = 0
local function autoClickTick(delta)
	clickBudget += delta * CONFIG.clickRate
	local sendable = math.floor(clickBudget)
	if sendable < 1 then return end
	clickBudget -= sendable
	for _ = 1, math.min(sendable, 6) do
		pcall(function() clickRemote:FireServer() end)
		STATE.clicks += 1
	end
end

local WEAPON_BY_ID = {}
for _, weapon in ipairs(WEAPONS) do WEAPON_BY_ID[weapon.id] = weapon end

-- Pad lookup by content, not by index. There are 27 wins weapons but only 21
-- pads in the hall, so HallWeapon<n> stops lining up with Weapon<n> and the old
-- index math silently equipped the wrong thing on the higher tiers. Each pad
-- carries a child model named exactly like the weapon it sells, which is the
-- reliable link.
local padCache = nil

local function weaponPads()
	if padCache then return padCache end
	padCache = {}
	if not weaponArea then return padCache end

	for _, pad in ipairs(weaponArea:GetChildren()) do
		local touch = pad:FindFirstChild("TouchPart", true)
		if touch then
			for _, child in ipairs(pad:GetChildren()) do
				if WEAPON_BY_ID[child.Name] then
					padCache[child.Name] = { pad = pad, touch = touch }
					break
				end
			end
		end
	end
	return padCache
end

-- Strongest weapon that is either already unlocked or affordable right now.
-- Affordability alone is not enough: with few wins the cheapest one would win
-- the comparison and the pad touch would downgrade an already better weapon.
-- Weapons are not owned in this game, they are gated purely by the wins total:
-- the pad hands over anything whose price the current balance covers, and stays
-- silent above that. The snapshot's UnlockedEquipment claims tiers the pad then
-- refuses (Weapon11 listed as unlocked while the pad demanded 200K wins against
-- a 73K balance), so it is deliberately ignored here.
local function bestWeapon(wins)
	local pads = weaponPads()
	local best
	for _, weapon in ipairs(WEAPONS) do
		if pads[weapon.id] and weapon.price <= wins then
			if not best or weapon.power > best.power then best = weapon end
		end
	end
	return best
end

local function currentPower()
	local equipped = WEAPON_BY_ID[STATE.weapon]
	return equipped and equipped.power or 0
end

-- Weapons are always upgraded to the best affordable tier - they are the damage
-- floor, so buying the cheap ones back after a rebirth is worth it.
-- Weapons are held by balance, not bought: drop below the price of the blade in
-- hand and the game hands it back and returns the previous one. So every other
-- purchase has to leave that price untouched, and the user's rule is stricter
-- still - only spend once the balance is at least twice the weapon's price.
local function weaponReserve()
	local equipped = WEAPON_BY_ID[STATE.weapon]
	return equipped and equipped.price or 0
end

-- Wins that may be spent on anything other than a weapon.
local function spendableWins()
	return STATE.wins - weaponReserve()
end

local function canSpend(cost)
	local reserve = weaponReserve()
	if reserve > 0 and STATE.wins < reserve * 2 then return false end
	return cost <= spendableWins()
end

local function upgradeWeapon()
	if not weaponArea then return end

	-- Wins are spent by eggs and auras between polls, so the balance is refreshed
	-- immediately before deciding. Acting on a four second old number was what
	-- sent it walking to tiers it could no longer pay for.
	snapshot()

	local best = bestWeapon(STATE.wins)
	if not best or best.id == STATE.weapon then return end
	if best.power <= currentPower() then return end          -- never trade down

	if best.price > STATE.wins then
		STATE.note = string.format("need %s wins for %s", shortNumber(best.price), best.name)
		return
	end

	local entry = weaponPads()[best.id]
	if not entry then
		STATE.note = "no pad for " .. best.name
		return
	end

	-- No teleport: the TouchInterest fires from any distance (verified from 1012
	-- studs away). Walking onto the pad used to slide the character across the
	-- neighbouring pads and equip whatever it brushed on the way.
	local before = STATE.weapon
	touch(entry.touch)
	task.wait(1.2)
	snapshot()

	-- Confirm the pad actually gave the intended weapon rather than a neighbour.
	if STATE.weapon == best.id then
		STATE.note = "weapon -> " .. best.name
	else
		STATE.note = string.format("weapon %s (wanted %s)", STATE.weapon, best.name)
		if STATE.weapon ~= before then padCache = nil end   -- remap next time
	end
end

local function equipBest()
	pcall(function() backpackRemote:FireServer("EquipBest", { Kind = "Equip" }) end)
	pcall(function() backpackRemote:FireServer("EquipBest", { Kind = "Gem" }) end)
end

local function equipBestPet()
	local main = plr.PlayerGui:FindFirstChild("Main")
	local pet = main and main:FindFirstChild("Pet")
	local button = pet and pet:FindFirstChild("EquipBest")
	if not button or not getconnections then return end
	for _, conn in pairs(getconnections(button.Activated)) do
		pcall(function() conn:Fire() end)
	end
end

-- The egg panel's Open button sends BuyEggEvent:FireServer(eggId, count) - the
-- argument-less call only charged wins without ever hatching anything. With the
-- arguments it works from anywhere, so no walking to the egg model is needed.
-- Verified: pets 1 -> 2 and wins -400 while standing inside a stage.
local function buyEgg(eggId, count)
	pcall(function() buyEggRemote:FireServer(eggId, count or 1) end)
	STATE.eggsBought += 1
	STATE.note = "opened " .. eggId
end

-- Inventory cleanup ----------------------------------------------------------
--
-- Pets cap at MaxPetStorage (35) and gear/gems fill up too, which blocks new
-- eggs and drops. The delete flow is UI driven and order matters:
--   1. press Delete    -> delete mode, CancelDelete becomes visible
--   2. click each row  -> marks it, and only now ConfirmDelete appears
--   3. press Confirm
-- Pressing Confirm before anything is selected does nothing at all, which is why
-- the first attempts looked broken. The owning panel must also be open.

-- Only one routine may drive the interface at a time. Without this the skill
-- purchase opens its panel, the pet cleanup opens another on top of it a moment
-- later, and both end up clicking into a window that is no longer there.
local uiBusy = false

local function withUI(name, fn)
	local waited = 0
	while uiBusy do
		task.wait(0.25)
		waited += 0.25
		if waited > 30 then return false end     -- never deadlock the loops
	end

	uiBusy = true
	STATE.uiOwner = name
	local ok, err = pcall(fn)
	uiBusy = false
	STATE.uiOwner = "-"
	if not ok then STATE.note = name .. " failed: " .. tostring(err):sub(1, 40) end
	return ok
end

local function fireGui(button)
	if not button or not getconnections then return 0 end
	local count = 0
	for _, conn in pairs(getconnections(button.Activated)) do
		pcall(function() conn:Fire() end)
		count += 1
	end
	return count
end

-- The HUD buttons toggle, so firing one blindly closes a panel that was already
-- open. That is what made the cleanup look random: every second pass shut the
-- window it had just opened.
local function openPanel(hudName, panel)
	if panel and panel.Visible then return true end
	local hud = plr.PlayerGui:FindFirstChild("HUD")
	local left = hud and hud:FindFirstChild("Left")
	local entry = left and left:FindFirstChild(hudName)
	local button = entry and entry:FindFirstChild("Button")
	if not button then return false end

	fireGui(button)
	task.wait(0.8)
	if panel and not panel.Visible then
		fireGui(button)          -- first press may have closed something else
		task.wait(0.8)
	end
	return not panel or panel.Visible
end

local function isEquippedRow(row)
	local marker = row:FindFirstChild("Equipped", true)
	return marker ~= nil and marker.Visible
end

-- Keeps the `keep` highest scoring rows plus everything equipped, deletes the
-- rest in batches. `scoreOf(row)` returns a comparable number.
local function cleanFrame(frame, listFrame, keep, scoreOf, label)
	if not frame or not listFrame then return end

	local rows = {}
	for _, row in ipairs(listFrame:GetChildren()) do
		if row:IsA("GuiButton") then
			table.insert(rows, { row = row, score = scoreOf(row) or 0, equipped = isEquippedRow(row) })
		end
	end
	if #rows <= keep then return end

	table.sort(rows, function(a, b) return a.score > b.score end)

	local deleteButton = frame:FindFirstChild("Delete")
	local confirmButton = frame:FindFirstChild("ConfirmDelete")
	if not deleteButton or not confirmButton then return end

	fireGui(deleteButton)
	task.wait(0.6)

	-- The gear and gem lists are virtualised (see Utils.InventoryVirtualList):
	-- rows are recycled as the list re-renders, so a long burst of clicks lands
	-- on the wrong entries. Mark a few, pause, and let the list settle.
	local marked = 0
	for index, entry in ipairs(rows) do
		if index > keep and not entry.equipped and marked < 8 then
			if entry.row.Parent then
				fireGui(entry.row)
				marked += 1
				task.wait(0.12)
			end
		end
	end
	if marked == 0 then
		fireGui(frame:FindFirstChild("CancelDelete"))
		return
	end

	task.wait(0.8)
	-- Pets need the explicit confirm. The gem list removes marked entries right
	-- away and never shows ConfirmDelete, so a missing confirm is not a failure
	-- and must not trigger CancelDelete.
	if confirmButton.Visible then fireGui(confirmButton) end
	STATE.deleted += marked
	STATE.note = string.format("deleted %d %s", marked, label)
	task.wait(0.6)

	-- Leave delete mode, otherwise the next pass starts in a half-selected state
	-- and its clicks do nothing.
	local cancel = frame:FindFirstChild("CancelDelete")
	if cancel and cancel.Visible then
		fireGui(cancel)
		task.wait(0.4)
	end
end

local function cleanPets()
	local main = plr.PlayerGui:FindFirstChild("Main")
	local pet = main and main:FindFirstChild("Pet")
	local list = pet and pet:FindFirstChild("ScrollingFrameB")
	if not list then return end

	-- The rows exist even while the panel is hidden, so the decision to open it
	-- at all is made first: nothing to do unless the inventory is over the keep
	-- limit, and no point re-checking until more eggs have been hatched.
	local rowCount = 0
	for _, row in ipairs(list:GetChildren()) do
		if row:IsA("GuiButton") then rowCount += 1 end
	end
	if rowCount <= CONFIG.petKeep then
		STATE.petsCleanedAt = STATE.eggsBought
		return
	end
	if STATE.petsCleanedAt == STATE.eggsBought then return end

	local wasVisible = pet.Visible
	if not openPanel("Pet", pet) then return end

	local eggHelperOk, helper = pcall(require, ReplicatedStorage.Config.EggHelper)
	local function scoreOf(row)
		local label = row:FindFirstChild("Name", true)
		local name = label and label.Text
		if not eggHelperOk or not name then return 0 end
		local ok, info = pcall(helper.GetPetInfo, name)
		return ok and type(info) == "table" and info.Addition or 0
	end

	-- One pass only marks a capped batch, so repeat until the target count is
	-- reached. Each pass re-reads the list because the rows are rebuilt.
	for _ = 1, 5 do
		local remaining = 0
		for _, row in ipairs(list:GetChildren()) do
			if row:IsA("GuiButton") then remaining += 1 end
		end
		if remaining <= CONFIG.petKeep then break end
		cleanFrame(pet, list, CONFIG.petKeep, scoreOf, "pets")
		task.wait(1.2)
	end

	STATE.petsCleanedAt = STATE.eggsBought
	-- Put the interface back the way it was found.
	if not wasVisible then
		local close = pet:FindFirstChild("CloseBtn")
		if close then fireGui(close) end
		task.wait(0.3)
		pet.Visible = false
	end
end

-- The game already ships auto-delete-by-rarity for gear and gems: EquipFrame and
-- GemFrame each have an Auto button opening an AutoFrame with one toggle per
-- rarity. Setting those once is far better than clicking individual rows - the
-- game then discards junk drops on its own, forever, with no panel open.
-- Toggle state is read from the marker images: `b` visible means on, `a` off.
local RARITIES = { "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic", "Godly" }

local function setAutoDelete(frame, threshold)
	if not frame then return 0 end
	local autoFrame = frame:FindFirstChild("AutoFrame")
	local autoButton = frame:FindFirstChild("Auto")
	if not autoFrame or not autoButton then return 0 end

	if not autoFrame.Visible then
		fireGui(autoButton)
		task.wait(0.5)
	end

	local changed = 0
	for index, rarity in ipairs(RARITIES) do
		local toggle = autoFrame:FindFirstChild(rarity)
		local onMarker = toggle and toggle:FindFirstChild("b")
		if toggle and onMarker then
			local isOn = onMarker.Visible
			local wantOn = index <= threshold
			if isOn ~= wantOn then
				fireGui(toggle)
				changed += 1
				task.wait(0.2)
			end
		end
	end

	fireGui(frame:FindFirstChild("AutoBack"))
	task.wait(0.3)
	return changed
end

-- Configures the game's own auto-delete for both tabs. Only opens the backpack
-- when a change is actually needed.
local function applyAutoDelete()
	local main = plr.PlayerGui:FindFirstChild("Main")
	local bag = main and main:FindFirstChild("BackPack")
	if not bag then return end
	local wasVisible = bag.Visible
	if not openPanel("BackPack", bag) then return end

	local changed = 0
	fireGui(bag:FindFirstChild("EquipBut"))
	task.wait(0.6)
	local gear = bag:FindFirstChild("Equip")
	changed += setAutoDelete(gear and gear:FindFirstChild("EquipFrame"), CONFIG.deleteRarity)

	fireGui(bag:FindFirstChild("GemBut"))
	task.wait(0.6)
	local gems = bag:FindFirstChild("Gem")
	changed += setAutoDelete(gems and gems:FindFirstChild("GemFrame"), CONFIG.deleteRarity)

	STATE.autoDeleteSet = CONFIG.deleteRarity
	STATE.note = string.format("auto-delete <= %s (%d toggles)", RARITIES[CONFIG.deleteRarity] or "off", changed)

	if not wasVisible then
		local close = bag:FindFirstChild("CloseBtn") or bag:FindFirstChild("Exit")
		if close then fireGui(close) end
		task.wait(0.3)
		bag.Visible = false
	end
end

-- Gear and gem rows expose RatingScore as an attribute, so no config lookup is
-- needed - the game's own rating is the ranking.
local function cleanBackpack()
	local main = plr.PlayerGui:FindFirstChild("Main")
	local bag = main and main:FindFirstChild("BackPack")
	if not bag then return end
	if not bag.Visible then return end

	local function scoreOf(row)
		return row:GetAttribute("RatingScore")
			or row:GetAttribute("Rank")
			or 0
	end

	-- Only one tab is rendered at a time; a hidden frame ignores every click.
	-- EquipBut / GemBut switch them.
	local function cleanTab(tabButton, frameName, innerName, keep, label)
		fireGui(bag:FindFirstChild(tabButton))
		task.wait(0.8)
		local outer = bag:FindFirstChild(frameName)
		local frame = outer and outer:FindFirstChild(innerName)
		if not frame then return end
		-- Several passes: each one re-reads the list, so recycled rows do not
		-- cause the wrong items to be marked.
		for _ = 1, 4 do
			local remaining = 0
			for _, row in ipairs((frame:FindFirstChild("ScrollingFrame") or frame):GetChildren()) do
				if row:IsA("GuiButton") then remaining += 1 end
			end
			if remaining <= keep then break end
			cleanFrame(frame, frame:FindFirstChild("ScrollingFrame"), keep, scoreOf, label)
			task.wait(1)
		end
	end

	cleanTab("EquipBut", "Equip", "EquipFrame", CONFIG.gearKeep, "gear")
	cleanTab("GemBut", "Gem", "GemFrame", CONFIG.gemKeep, "gems")
end

-- Auras cost wins and multiply future win income (Aura1 100 wins for +5%,
-- Aura10 7M for +100%), so they pay for themselves. Each row in the aura panel
-- has a Buy button priced in wins and an RBuy button priced in Robux - only Buy
-- is ever touched.
local function fireButton(button)
	if not button or not getconnections then return false end
	local fired = false
	for _, conn in pairs(getconnections(button.Activated)) do
		pcall(function() conn:Fire() end)
		fired = true
	end
	return fired
end

local function buyBestAura()
	local rows = plr.PlayerGui:FindFirstChild("Main")
	rows = rows and rows:FindFirstChild("Aura")
	rows = rows and rows:FindFirstChild("ScrollingFrame")
	if not rows then return end

	local owned = STATE.ownedAuras or {}
	local pick
	for _, aura in ipairs(AURAS) do
		if not owned[aura.id] and canSpend(aura.price) then
			if not pick or aura.price > pick.price then pick = aura end
		end
	end
	if not pick then return end

	local row = rows:FindFirstChild("Stage" .. pick.index)
	if not row then return end

	if fireButton(row:FindFirstChild("Buy")) then
		task.wait(1)
		snapshot()
		if (STATE.ownedAuras or {})[pick.id] then
			STATE.auras += 1
			STATE.note = "aura " .. pick.name .. " (+" .. math.floor((pick.bonus - 1) * 100) .. "% wins)"
			task.wait(0.4)
			fireButton(row:FindFirstChild("Equip"))
		else
			STATE.note = "aura " .. pick.name .. " refused"
		end
	end
end

-- Skills ---------------------------------------------------------------------
--
-- Skills are extra attacks bound to Q/E/R and are bought with wins. Prices come
-- from SkillHelper.GetWins(id): Stab 50, JianQi1 2000, DunJi 40000, Fire 1M,
-- Ice 20M. GetSkillState tells which are already unlocked.
--
-- The panel wiring is confusing on purpose: the visible purchase button in
-- RightFrame is named "Rebirth" and its Title label shows the wins price, while
-- Equip/Unequip stay hidden until the skill is owned. Flow is
--   select Skill_<ID> row -> press RightFrame.Rebirth (buy) -> press Equip.

local function skillState()
	local remote = Remotes:FindFirstChild("GetSkillState")
	if not remote then return nil end
	local ok, state = pcall(function() return remote:InvokeServer() end)
	return ok and type(state) == "table" and state or nil
end

-- The full price ladder, cheapest first, with what is still missing. Also used
-- by the spend priority so eggs cannot drain the wins a skill is waiting for.
local function skillShoppingList()
	local state = skillState()
	local helperOk, helper = pcall(require, ReplicatedStorage.Config.SkillHelper)
	if not state or not helperOk then return {} end

	local list = {}
	for _, entry in pairs(state) do
		if type(entry) == "table" and entry.ID and not entry.Unlocked then
			local priceOk, price = pcall(helper.GetWins, entry.ID)
			price = priceOk and tonumber(price) or nil
			if price and price > 0 then
				table.insert(list, {
					id = entry.ID,
					name = entry.Name or entry.ID,
					price = price,
					slot = entry.Slot,
				})
			end
		end
	end
	table.sort(list, function(a, b) return a.price < b.price end)
	return list
end

local function skillUpgradePending()
	for _, skill in ipairs(skillShoppingList()) do
		if canSpend(skill.price) then return true, skill end
	end
	return false
end

local function buySkills()
	local main = plr.PlayerGui:FindFirstChild("Main")
	local panel = main and main:FindFirstChild("Skill")
	if not panel then return end

	local state = skillState()
	if not state then return end

	local helperOk, helper = pcall(require, ReplicatedStorage.Config.SkillHelper)
	if not helperOk then return end

	-- Cheapest missing skill first, so early wins are not held hostage by a
	-- twenty-million tier.
	local wanted = {}
	for _, entry in pairs(state) do
		if type(entry) == "table" and entry.ID and not entry.Unlocked then
			local priceOk, price = pcall(helper.GetWins, entry.ID)
			price = priceOk and tonumber(price) or nil
			if price and price > 0 and canSpend(price) then
				table.insert(wanted, { id = entry.ID, name = entry.Name or entry.ID, price = price })
			end
		end
	end
	if #wanted == 0 then return end
	table.sort(wanted, function(a, b) return a.price < b.price end)

	-- The HUD skill button does not respond to a synthetic click the way Pet and
	-- BackPack do (the panel likely opens from the skill altar in the hall), but
	-- the buy handler only cares that the frame is rendered, so it is shown
	-- directly and hidden again afterwards.
	local wasVisible = panel.Visible
	panel.Visible = true
	task.wait(0.6)

	local list = panel:FindFirstChild("LeftFrame")
	list = list and list:FindFirstChild("Trails")
	list = list and list:FindFirstChild("LeftScro")
	local right = panel:FindFirstChild("RightFrame")
	if not list or not right then
		panel.Visible = wasVisible
		return
	end

	for _, skill in ipairs(wanted) do
		local row = list:FindFirstChild("Skill_" .. skill.id)
		if row then
			fireGui(row)
			task.wait(0.8)
			fireGui(right:FindFirstChild("Rebirth"))   -- the wins purchase button
			task.wait(1.5)
			local equip = right:FindFirstChild("Equip")
			if equip and equip.Visible then
				fireGui(equip)
				task.wait(0.8)
			end
			snapshot()
			STATE.skillsBought += 1
			STATE.note = "skill " .. skill.name .. " (" .. shortNumber(skill.price) .. ")"
		end
	end

	panel.Visible = wasVisible
end

-- Fires every equipped skill that is off cooldown.
--
-- Calling SkillController:UseSkill directly incremented a counter but nothing
-- happened in game - it wants context the raw call does not carry. The on screen
-- Q/E/R buttons in HUD.Down.Skill1..3 run the real handler, so those are pressed
-- instead, exactly like a human hitting the key. UseSkill stays as a fallback
-- for the case where the HUD is missing.
local function castSkills()
	-- Slot 1 is Sprint, a forward dash. Fired outside a fight it drags the
	-- character across the hall - over the weapon pads, off the stage pad, away
	-- from wherever it was parked. So skills only ever go off with something
	-- alive to hit.
	if aliveMobs() < 1 then return end

	local hud = plr.PlayerGui:FindFirstChild("HUD")
	local down = hud and hud:FindFirstChild("Down")
	local fired = 0

	if down then
		-- Slot 1 holds Sprint, a forward dash. Even mid fight it yanks the
		-- character past the mob it was hitting, so it stays off entirely while
		-- that is what sits in the slot.
		local firstSlot = CONFIG.skipDash and 2 or 1
		for slot = firstSlot, 3 do
			local holder = down:FindFirstChild("Skill" .. slot)
			local button = holder and holder:FindFirstChild("Button")
			if button and button.Visible then
				-- A skill on cooldown shows a darkened overlay; firing anyway is
				-- harmless, the handler just ignores it.
				if fireGui(button) > 0 then
					fired += 1
					STATE.casts += 1
				end
			end
		end
	end

	if fired > 0 then return end

	local ctrl = CTRL.skill
	if not ctrl then return end
	local ok, ids = pcall(ctrl.GetEquippedSkillIds, ctrl)
	if not ok or type(ids) ~= "table" then return end
	for _, id in pairs(ids) do
		if id then
			local gotIt, remaining = pcall(ctrl.GetCooldownRemaining, ctrl, id)
			if not gotIt or (tonumber(remaining) or 0) <= 0 then
				pcall(ctrl.UseSkill, ctrl, id)
				STATE.casts += 1
			end
		end
	end
end

-- Bosses and some mobs walk away, which drags a two second clear into twenty.
-- This pulls the character next to whatever is still alive.
local function chaseNearestMob()
	local ctrl = stageCtrl()
	local stage = ctrl and ctrl.activeLocalStage
	local hrp = rootPart()
	if not stage or type(stage.Mobs) ~= "table" or not hrp then return end

	local bestPos, bestDist
	for _, mob in pairs(stage.Mobs) do
		if type(mob) == "table" and not mob.Dead and typeof(mob.Model) == "Instance" then
			local ok, pivot = pcall(function() return mob.Model:GetPivot().Position end)
			if ok then
				local distance = (pivot - hrp.Position).Magnitude
				if not bestDist or distance < bestDist then
					bestPos, bestDist = pivot, distance
				end
			end
		end
	end

	-- Never chase across the map. A mob further away than this belongs to another
	-- stage or is mid despawn, and following it teleported the character out of
	-- the current run.
	if not bestPos or bestDist <= CONFIG.chaseRange or bestDist > 250 then return end
	-- Land just short of the mob and face it, so the swing hitbox lines up.
	local offset = (hrp.Position - bestPos)
	offset = offset.Magnitude > 0.1 and offset.Unit or Vector3.new(0, 0, 1)
	hrp.CFrame = CFrame.new(bestPos + offset * 4 + Vector3.new(0, 2, 0), bestPos)
	STATE.chases += 1
end

-- Every egg has a pool of four pets; the one with the highest Addition is what
-- the egg is actually farmed for. Once enough copies of that pet are owned the
-- egg is finished - only three can be equipped, so further hatches are wasted
-- wins. Verified against the live account: WarriorEgg tops out at Crocodile
-- (Addition 3.15) and twelve of them were already sitting in the inventory.
local EGG_BEST = {}
do
	local ok, helper = pcall(require, ReplicatedStorage.Config.EggHelper)
	if ok and helper.GetPoolData then
		for _, egg in ipairs(EGGS) do
			local gotPool, pool = pcall(helper.GetPoolData, egg.id)
			if gotPool and type(pool) == "table" then
				local best
				for _, pet in pairs(pool) do
					if type(pet) == "table" and pet.Name then
						if not best or (pet.Addition or 0) > (best.Addition or 0) then best = pet end
					end
				end
				if best then
					EGG_BEST[egg.id] = { name = best.Name, addition = best.Addition or 0 }
				end
			end
		end
	end
end

-- Counts copies by reading the pet list rows, which exist even while the panel
-- is closed. GetPetIndex only reports distinct species, not how many are held.
local function ownedPetCount(petName)
	local main = plr.PlayerGui:FindFirstChild("Main")
	local pet = main and main:FindFirstChild("Pet")
	local list = pet and pet:FindFirstChild("ScrollingFrameB")
	if not list or not petName then return 0 end

	local count = 0
	for _, row in ipairs(list:GetChildren()) do
		if row:IsA("GuiButton") then
			local label = row:FindFirstChild("Name", true)
			if label and label.Text == petName then count += 1 end
		end
	end
	return count
end

-- Strongest Addition among the pets currently held.
local function bestOwnedAddition()
	local main = plr.PlayerGui:FindFirstChild("Main")
	local pet = main and main:FindFirstChild("Pet")
	local list = pet and pet:FindFirstChild("ScrollingFrameB")
	if not list then return 0 end

	local ok, helper = pcall(require, ReplicatedStorage.Config.EggHelper)
	if not ok then return 0 end

	local best = 0
	for _, row in ipairs(list:GetChildren()) do
		if row:IsA("GuiButton") then
			local label = row:FindFirstChild("Name", true)
			if label then
				local gotIt, info = pcall(helper.GetPetInfo, label.Text)
				if gotIt and type(info) == "table" and (info.Addition or 0) > best then
					best = info.Addition
				end
			end
		end
	end
	return best
end

-- An egg is done when either enough copies of its top pet are held, or that top
-- pet is no better than something already owned - hatching a Grass Egg for a
-- Deer (1.85) is pointless once a Crocodile (3.15) sits in the inventory.
local function eggIsFinished(eggId)
	local best = EGG_BEST[eggId]
	if not best then return false end
	if ownedPetCount(best.name) >= CONFIG.petCopies then return true end
	return best.addition <= bestOwnedAddition()
end

-- Strongest egg the wins allow, or the one picked by hand in the panel.
-- Re-equips the strongest weapon already owned. Buying is not the only way to
-- end up on the wrong one: a rebirth, a manual swap or a mistimed pad touch all
-- leave a better blade sitting unused in the inventory.
local function ensureBestEquipped()
	local best = bestWeapon(STATE.wins)
	if not best or best.id == STATE.weapon then return end
	if best.power <= currentPower() then return end

	local entry = weaponPads()[best.id]
	if not entry then return end
	touch(entry.touch)
	task.wait(1)
	snapshot()
	if STATE.weapon == best.id then
		STATE.note = "re-equipped " .. best.name
	end
end

-- True when a strictly better weapon is affordable right now. Weapons and eggs
-- sit in the same price bracket, and damage is what unlocks the next stage, so
-- the weapon always gets the wins first.
local function weaponUpgradePending()
	local best = bestWeapon(STATE.wins)
	if not best then return false end
	return best.power > currentPower() and best.price <= STATE.wins
end

local function buyBestEgg()
	-- Spend order is weapon, then skill, then egg. Weapons and skills raise
	-- damage directly and sit in the same price bracket as the eggs, so an egg
	-- purchase must never eat the wins they are waiting on.
	-- Weapons win ties and near ties: a 200K blade beats a 225K egg every time,
	-- so the upgrade is pulled forward here instead of merely blocking the egg
	-- and hoping the weapon loop gets there before the balance is spent.
	if CONFIG.autoWeapon and weaponUpgradePending() then
		local best = bestWeapon(STATE.wins)
		STATE.note = "weapon first: " .. (best and best.name or "?")
		upgradeWeapon()
		return
	end
	if CONFIG.autoSkill then
		local pending, skill = skillUpgradePending()
		if pending then
			STATE.note = "skill " .. skill.name .. " first, egg on hold"
			return
		end
	end

	local pick
	if CONFIG.autoEggBest then
		-- Most expensive egg that is both affordable and not already maxed out.
		for _, egg in ipairs(EGGS) do
			if canSpend(egg.price) and not eggIsFinished(egg.id) then
				if not pick or egg.price > pick.price then pick = egg end
			end
		end
		if not pick then
			-- Everything reachable is done; hold the wins for the next tier.
			local nextTier
			for _, egg in ipairs(EGGS) do
				if not canSpend(egg.price) and not eggIsFinished(egg.id) then
					if not nextTier or egg.price < nextTier.price then nextTier = egg end
				end
			end
			if nextTier then
				STATE.note = string.format("eggs done, saving %s for %s",
					shortNumber(nextTier.price), nextTier.name)
			end
			return
		end
	else
		local chosen = EGGS[CONFIG.egg]
		if chosen and canSpend(chosen.price) then
			if eggIsFinished(chosen.id) then
				local best = EGG_BEST[chosen.id]
				STATE.note = string.format("%s done (%dx %s)", chosen.name,
					CONFIG.petCopies, best and best.name or "best pet")
				return
			end
			pick = chosen
		end
	end
	if not pick then return end

	-- Egg memory: the best egg tier ever bought is remembered in _G across
	-- rebirths and re-executes. After a rebirth wipes the wins, the cheap eggs
	-- become "affordable" again, and hatching those is a waste - their pets are
	-- far below what the account already had. So anything well below the peak
	-- tier is skipped and the wins are saved until that tier is reachable again.
	_G.__LOOTEVO_PEAKEGG = _G.__LOOTEVO_PEAKEGG or 0
	local peak = _G.__LOOTEVO_PEAKEGG
	if peak > 0 and pick.price < peak / 10 then
		STATE.note = "saving wins for " .. shortNumber(peak) .. " egg tier"
		return
	end
	_G.__LOOTEVO_PEAKEGG = math.max(peak, pick.price)

	-- Spend the surplus: keep hatching the same egg while the wins hold, capped
	-- so a single call cannot drain everything the weapon upgrade needs. Stops
	-- early the moment the egg's top pet reaches the equip limit.
	local best = EGG_BEST[pick.id]
	for _ = 1, 5 do
		if not canSpend(pick.price) then break end
		if eggIsFinished(pick.id) then
			STATE.note = string.format("%s done (%dx %s)", pick.name,
				CONFIG.petCopies, best and best.name or "best pet")
			break
		end
		buyEgg(pick.id, 1)
		task.wait(0.6)
		snapshot()
	end
	equipBestPet()
end

-- RebirthRequest:FireServer() takes no arguments, but the server rejects it
-- while the player is inside a stage - fired from the hall it goes through.
-- Verified: Rebirth 1 -> 2, level and damage reset to 1, multiplier 3 kept.
local lastRebirth = 0
local function tryRebirth()
	if STATE.needLevel <= 0 or STATE.level < STATE.needLevel then return end
	if os.clock() - lastRebirth < 15 then return end
	lastRebirth = os.clock()

	local before = STATE.rebirth
	STATE.phase = "rebirth: to hall"
	goHall()
	task.wait(2)                                  -- let the stage state clear
	pcall(function() rebirthRemote:FireServer() end)
	task.wait(2.5)
	snapshot()
	if STATE.rebirth > before then
		STATE.rebirths += 1
		STATE.note = string.format("rebirth %d -> %d", before, STATE.rebirth)
	else
		STATE.note = "rebirth refused at lvl " .. STATE.level
	end
end

-- Codes live in Config.CodeHelper with an Enabled flag, so they are read rather
-- than hardcoded. Each one grants DoublePower and DoubleVictoryPoints potions;
-- redeeming is free, one shot per account, and refusals are silent.
local function redeemCodes()
	local ok, helper = pcall(require, ReplicatedStorage.Config.CodeHelper)
	if not ok or type(helper) ~= "table" or not helper.GetAll then return end
	local list = select(2, pcall(helper.GetAll))
	if type(list) ~= "table" then return end

	local remote = Remotes:FindFirstChild("RedeemCodeFunction")
	if not remote then return end

	local tried = 0
	for _, entry in pairs(list) do
		if type(entry) == "table" and entry.Enabled and entry.Code then
			pcall(function() remote:InvokeServer(entry.Code) end)
			tried += 1
			task.wait(1)
		end
	end
	STATE.codesDone = true
	STATE.note = "redeemed " .. tried .. " codes"
end

-- Which stage to run this cycle.
--
-- "smart ladder" is the interesting one. It walks a single cursor:
--   cleared fast (under fastSeconds)  -> climb one stage
--   cleared slowly                    -> stay, the stage is still worth wins
--   failed / timed out                -> drop one stage, bank farmRuns worth of
--                                        wins there, then retry the blocker
-- A rebirth wipes wins, weapons and levels but keeps HighestClearedStage, so the
-- cursor restarts from stage 1 and climbs back up on its own.
local function pickStage()
	local mode = FARM_MODES[CONFIG.farmMode]
	if mode == "fixed stage" then return math.clamp(CONFIG.stage, 1, MAX_STAGE) end
	if mode == "repeat cleared" then return math.max(1, STATE.cleared) end
	if mode == "push next" then
		local nextStage = math.clamp(STATE.cleared + 1, 1, MAX_STAGE)
		if STATE.tooHard[nextStage] and STATE.wins < STATE.tooHard[nextStage] then
			return math.max(1, STATE.cleared)
		end
		return nextStage
	end
	return math.clamp(STATE.ladder, 1, MAX_STAGE)
end

-- Applies the ladder rules after a run. `seconds` is nil when the run failed.
local function updateLadder(stage, seconds)
	if FARM_MODES[CONFIG.farmMode] ~= "smart ladder" then return end

	if not seconds then
		STATE.blockedAt = stage
		STATE.bankRuns = 0
		STATE.ladder = math.max(1, stage - 1)
		STATE.note = string.format("stage %d too strong -> banking on %d", stage, STATE.ladder)
		return
	end

	STATE.lastClear = seconds

	-- Working the fallback stage: bank a few runs, then take another swing at
	-- the stage that blocked us. A clear inside the fast window means the
	-- character has outgrown this tier, so the remaining bank runs are skipped
	-- and the blocker is retried right away - otherwise a fast clear still sat
	-- out four more rounds before moving.
	if STATE.blockedAt > 0 and stage < STATE.blockedAt then
		STATE.bankRuns += 1
		if seconds <= CONFIG.fastSeconds or STATE.bankRuns >= CONFIG.farmRuns then
			STATE.bankRuns = 0
			STATE.ladder = STATE.blockedAt
			STATE.note = string.format("retrying stage %d (dmg %s)", STATE.blockedAt, shortNumber(STATE.damage))
		end
		return
	end

	-- A clear is a clear. Boss stages legitimately take longer than the fast
	-- window, and the old rule kept re-running them forever because only a fast
	-- clear counted as progress. Duration now only decides how far to move:
	-- trivial clears below the known frontier jump, everything else steps once.
	STATE.blockedAt = 0

	local step = 1
	if stage < STATE.cleared and seconds <= CONFIG.fastSeconds / 2 then
		step = math.max(1, math.floor((STATE.cleared - stage) / 2))
	end

	STATE.ladder = math.min(stage + step, MAX_STAGE)
	STATE.note = string.format("stage %d in %.1fs -> %s %d",
		stage, seconds, step > 1 and "jumping to" or "climbing to", STATE.ladder)
end

-- One full run: hall -> stage -> wait for the kill -> claim the win.
local function farmCycle()
	local want = pickStage()
	-- Compared at the end of the run: only an actual rebirth invalidates the
	-- result, so the ladder is not rewound by a run that finished a moment after
	-- the reset. Must be captured here - when this was missing the comparison
	-- ran against nil, every single run was discarded, and the ladder never left
	-- stage 1.
	local rebirthAtStart = STATE.rebirth
	STATE.phase = "hall"
	goHall()
	task.wait(1)

	STATE.phase = "enter " .. want
	if not enterStage(want) then
		STATE.note = "stage " .. want .. " has no pad"
		task.wait(1)
		return
	end

	-- Wait for mobs to spawn, then for them to die. The clock starts at entry
	-- because that is what "cleared it in under five seconds" means in practice.
	local started = os.clock()
	local deadline = started + CONFIG.stageTimeout
	local spawnDeadline = started + CONFIG.spawnTimeout
	local sawMobs = false
	diedFlag = false
	while os.clock() < deadline and CONFIG.autoFarm do
		if diedFlag then break end
		local alive = aliveMobs()
		STATE.mobs = alive
		if alive > 0 then
			sawMobs = true
			STATE.phase = string.format("fighting %d (%.1fs)", alive, os.clock() - started)
			-- Q/E/R attacks belong in the fight itself, not only in the
			-- background ticker: this fires them the moment mobs are up.
			if CONFIG.castSkills then castSkills() end
			if CONFIG.chaseMobs then pcall(chaseNearestMob) end
		elseif sawMobs then
			break   -- everything that spawned is down
		else
			STATE.phase = "waiting for spawn"
			-- Stages above the unlocked one never spawn anything. Waiting the
			-- full timeout there wastes 20s per cycle, so bail out early.
			if os.clock() > spawnDeadline then break end
		end
		task.wait(0.3)
	end

	local elapsed = os.clock() - started

	-- Died mid run: that is a loss, not a slow clear.
	if diedFlag then
		diedFlag = false
		STATE.deaths += 1
		if STATE.rebirth ~= rebirthAtStart then goHall() return end
		STATE.tooHard[want] = STATE.wins * 2 + 50
		STATE.note = string.format("died on stage %d after %.1fs", want, elapsed)
		updateLadder(want, nil)
		task.wait(2)                      -- let the respawn settle
		goHall()
		return
	end

	-- No spawn means the stage is not actually available yet. Counting that as a
	-- fast clear made the ladder run away into empty stages and never claim a
	-- single win, so it is a failure and drops the cursor back.
	if not sawMobs then
		-- A stage at or below the cleared frontier that stays empty is usually a
		-- timing hiccup right after entering, not a locked stage. Give it one
		-- more attempt before demoting the cursor.
		STATE.noSpawn[want] = (STATE.noSpawn[want] or 0) + 1
		if want <= STATE.cleared and STATE.noSpawn[want] < 2 then
			STATE.note = "no spawn on stage " .. want .. " -> retrying"
			goHall()
			return
		end
		STATE.noSpawn[want] = 0
		STATE.note = "no spawn on stage " .. want .. " -> not unlocked"
		updateLadder(want, nil)
		goHall()
		return
	elseif aliveMobs() > 0 then
		STATE.tooHard[want] = STATE.wins * 2 + 50
		updateLadder(want, nil)              -- failed
		goHall()
		return
	end

	STATE.phase = "claiming"
	task.wait(0.6)
	claimWin(want)
	task.wait(0.8)
	snapshot()
	STATE.runs += 1
	STATE.noSpawn[want] = 0

	-- A rebirth during this run already reset the ladder; writing this stage's
	-- outcome now would undo it and leave the cursor back where it started.
	if STATE.rebirth ~= rebirthAtStart then
		STATE.note = "rebirth mid-run, result discarded"
		return
	end
	if sawMobs then updateLadder(want, elapsed) end

	-- upgradeWeapon teleports and equipBestPet clicks a panel button, so the
	-- post-run chores take the same interface lock the cleanup routines use.
	if CONFIG.autoWeapon then withUI("weapon", upgradeWeapon) end
	if CONFIG.autoSkill then withUI("skills", buySkills) end
	if CONFIG.autoEquip then equipBest() end
	if CONFIG.autoBuyEgg then buyBestEgg() end
	if CONFIG.autoPet then withUI("pet equip", equipBestPet) end
end

-- UI -------------------------------------------------------------------------
--
-- The panel is built from ui-template.lua, the shared house design ported from
-- the Bloodline-style mock. Nothing game specific lives in the look, only in the
-- pages below, so every script in this folder reads the same way.

local UI
do
	local ok, result = pcall(function()
		-- hub first, readfile is the fallback for a hand-shipped run
		return (_G.__SEL and _G.__SEL.ui) or loadstring(readfile("ui-template.lua"))()
	end)
	if not ok or type(result) ~= "table" then
		error("[lootevo] ui-template.lua could not be loaded - put it in the "
			.. "executor workspace folder next to this script (" .. tostring(result) .. ")")
	end
	UI = result
end

-- Every switch on this panel survives a rejoin. UI.config merges the saved file
-- into CONFIG HERE, before the panel is built - the controls read their initial
-- value out of CONFIG when they are created, so they come up on the saved state
-- by themselves and nothing below had to be told about any of this.
UI.config("lootevo", CONFIG)

local win = UI.Window({
	name = "LootEvo",
	title = "LOOT",
	accentTitle = "EVO",
	subtitle = "seltonmt",
	badge = "◈",
	width = 900,
	height = 570,
})
_G.__LOOTEVO_GUI = win.gui

-- CONFIG-backed toggle, so a row cannot drift out of sync with the flag it owns.
local function toggle(card, text, key, hint, tone, onChange)
	return card:Toggle(text, CONFIG[key], function(value)
		CONFIG[key] = value
		if onChange then onChange(value) end
	end, hint, tone)
end

-- FARMING ---------------------------------------------------------------------
local farmPage = win:Page("FARMING", UI.icon.map)

local farmCard = farmPage:Card("AUTO FARM", 1)
toggle(farmCard, "Auto Farm", "autoFarm",
	"enter stage, fight, claim, repeat", UI.theme.warn)
local refreshMode = farmCard:Stepper("Mode",
	function() return FARM_MODES[CONFIG.farmMode] end,
	function(delta)
		CONFIG.farmMode = ((CONFIG.farmMode - 1 + delta) % #FARM_MODES) + 1
	end)
local refreshStage = farmCard:Stepper("Stage",
	function()
		return FARM_MODES[CONFIG.farmMode] == "fixed stage"
			and tostring(CONFIG.stage) or ("auto " .. pickStage())
	end,
	function(delta)
		CONFIG.farmMode = 4
		CONFIG.stage = math.clamp(CONFIG.stage + delta, 1, MAX_STAGE)
	end)

local timingCard = farmPage:Card("TIMING", 1)
timingCard:Stepper("Jump under s",
	function() return tostring(CONFIG.fastSeconds) end,
	function(delta) CONFIG.fastSeconds = math.clamp(CONFIG.fastSeconds + delta, 2, 30) end,
	"a clear this fast jumps the ladder ahead")
timingCard:Stepper("Give up after s",
	function() return tostring(CONFIG.stageTimeout) end,
	function(delta) CONFIG.stageTimeout = math.clamp(CONFIG.stageTimeout + delta * 5, 10, 120) end,
	"counts as a failure and drops one stage")
timingCard:Stepper("Bank runs",
	function() return tostring(CONFIG.farmRuns) end,
	function(delta) CONFIG.farmRuns = math.clamp(CONFIG.farmRuns + delta, 1, 20) end,
	"runs on the fallback stage before retrying the blocker")

local ladderCard = farmPage:Card("LADDER", 2)
local ladderOut = ladderCard:Readout(10)

local runCard = farmPage:Card("THIS SESSION", 2)
local runOut = runCard:Readout(7)

-- COMBAT ----------------------------------------------------------------------
local combatPage = win:Page("COMBAT", UI.icon.sword)

local clickCard = combatPage:Card("CLICKING", 1)
toggle(clickCard, "Auto Click", "autoClick",
	"ClickRequest, the real damage engine", UI.theme.warn)
clickCard:Stepper("Clicks/sec",
	function() return tostring(CONFIG.clickRate) end,
	function(delta) CONFIG.clickRate = math.clamp(CONFIG.clickRate + delta * 2, 2, 40) end,
	"server throttles per click, throughput still rises")

local skillCard = combatPage:Card("SKILLS", 1)
toggle(skillCard, "Cast Skills (Q/E/R)", "castSkills")
toggle(skillCard, "Skip dash skill (Q)", "skipDash",
	"the dash drags you off the stage pad")

local survivalCard = combatPage:Card("SURVIVAL", 2)
toggle(survivalCard, "God Mode", "godMode",
	"pins health; the remote block is unproven", UI.theme.warn, applyGodMode)
toggle(survivalCard, "Chase runaway mobs", "chaseMobs",
	"bosses walk away from the spawn point")
survivalCard:Stepper("Chase range",
	function() return tostring(CONFIG.chaseRange) end,
	function(delta) CONFIG.chaseRange = math.clamp(CONFIG.chaseRange + delta, 3, 40) end,
	"capped so the chase cannot leave the stage")

-- SHOP ------------------------------------------------------------------------
local shopPage = win:Page("SHOP", UI.icon.coin)

local weaponCard = shopPage:Card("WEAPONS", 1)
toggle(weaponCard, "Buy Weapons", "autoWeapon",
	"held by the wins balance, not owned")
local weaponLabel = weaponCard:Label("weapon -")
weaponCard:Button("Buy best weapon now", function()
	withUI("weapon", upgradeWeapon)
end)

local skillShopCard = shopPage:Card("SKILLS", 1)
toggle(skillShopCard, "Buy Skills", "autoSkill",
	"extra attacks on Q/E/R, priced in wins")

local auraCard = shopPage:Card("AURAS", 2)
toggle(auraCard, "Buy Auras", "autoAura",
	"multiplies win income; only the wins-priced Buy")

local rebirthCard = shopPage:Card("REBIRTH", 2)
toggle(rebirthCard, "Rebirth at level", "autoRebirth",
	"wipes level, damage, wins and weapons", UI.theme.warn)
rebirthCard:Button("Rebirth now", function()
	if STATE.needLevel > 0 and STATE.level < STATE.needLevel then
		STATE.note = string.format("need level %d to rebirth (at %d)",
			STATE.needLevel, STATE.level)
		return
	end
	lastRebirth = 0          -- ignore the cooldown for a deliberate press
	tryRebirth()
end, UI.theme.bad)
rebirthCard:Button("Reset ladder (as after rebirth)", function()
	resetProgression("manual")
end, UI.theme.warn)

-- EGGS AND PETS ---------------------------------------------------------------
local petPage = win:Page("EGGS & PETS", UI.icon.flask)

local eggCard = petPage:Card("EGGS", 1)
toggle(eggCard, "Buy Eggs", "autoBuyEgg",
	"BuyEggEvent(eggId, count), works from anywhere")
toggle(eggCard, "Pick best egg", "autoEggBest")
local refreshEgg = eggCard:Stepper("Egg",
	function()
		if CONFIG.autoEggBest then return "auto best" end
		local egg = EGGS[CONFIG.egg]
		return egg and (egg.name .. " " .. shortNumber(egg.price)) or "-"
	end,
	function(delta)
		CONFIG.autoEggBest = false
		CONFIG.egg = math.clamp(CONFIG.egg + delta, 1, #EGGS)
	end)

local petCard = petPage:Card("PETS", 2)
toggle(petCard, "Equip best pet", "autoPet")
petCard:Stepper("Pet copies",
	function() return tostring(CONFIG.petCopies) end,
	function(delta) CONFIG.petCopies = math.clamp(CONFIG.petCopies + delta, 1, 10) end,
	"an egg is done once its top pet is held this often")
toggle(petCard, "Sell bad pets", "cleanPets",
	"pets have no auto-delete, this clicks the rows", UI.theme.warn)
petCard:Stepper("Keep pets",
	function() return tostring(CONFIG.petKeep) end,
	function(delta) CONFIG.petKeep = math.clamp(CONFIG.petKeep + delta, 3, 34) end)

-- INVENTORY -------------------------------------------------------------------
local bagPage = win:Page("INVENTORY", UI.icon.bag)

local RARITY_NAMES = { "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic", "Godly" }

local gearCard = bagPage:Card("GEAR", 1)
toggle(gearCard, "Equip best gear", "autoEquip",
	"BackPackActionEvent EquipBest")
toggle(gearCard, "Auto-delete junk", "cleanBag",
	"sets the game's own per-rarity auto-delete", UI.theme.warn, function(on)
		if on then task.spawn(function() withUI("auto-delete", applyAutoDelete) end) end
	end)
gearCard:Stepper("Delete up to",
	function() return RARITY_NAMES[CONFIG.deleteRarity] or "off" end,
	function(delta)
		CONFIG.deleteRarity = math.clamp(CONFIG.deleteRarity + delta, 0, 7)
		if CONFIG.cleanBag then
			task.spawn(function() withUI("auto-delete", applyAutoDelete) end)
		end
	end)

local bagStateCard = bagPage:Card("STATE", 2)
local bagOut = bagStateCard:Readout(6)

-- STATUS ----------------------------------------------------------------------
local statusPage = win:Page("STATUS", UI.icon.chart)

local liveCard = statusPage:Card("LIVE", 1)
local liveOut = liveCard:Readout(11)

local progressCard = statusPage:Card("PROGRESS", 2)
local progressOut = progressCard:Readout(9)

local toolCard = statusPage:Card("TOOLS", 2)
toolCard:Button("Unstuck movement + camera", unstuck, UI.theme.bad)
toolCard:Button("Redeem codes", redeemCodes)
toolCard:Button("Rescan controllers", function()
	CTRL.lastScan = 0
	scanControllers()
	STATE.note = "controllers rescanned"
end)

-- Der Home-Tab: das GitHub-Commit-Log als Changelog plus der aktuelle Lauf.
-- Zuletzt deklariert, aber das Template schiebt ihn an den Anfang der Leiste -
-- er ist immer das erste Icon und die Seite, auf der das Panel aufgeht.
pcall(function() win:Home() end)

win:Refresh()


-- Loops ----------------------------------------------------------------------

local function loop(interval, enabled, fn)
	task.spawn(function()
		while _G.__LOOTEVO == generation do
			if CONFIG[enabled] then pcall(fn) end
			task.wait(interval)
		end
	end)
end

-- Driven off Heartbeat so the rate holds regardless of what else is running.
do
	local last = os.clock()
	RunService.Heartbeat:Connect(function()
		if _G.__LOOTEVO ~= generation then return end
		local now = os.clock()
		local delta = now - last
		last = now
		if CONFIG.autoClick then autoClickTick(math.min(delta, 0.25)) end
	end)
end

loop(5, "autoRebirth", tryRebirth)
loop(15, "autoBuyEgg", buyBestEgg)
loop(12, "autoAura", buyBestAura)
loop(1.2, "castSkills", castSkills)   -- no UI involved, safe to run in parallel

-- Everything below touches panels, so each takes the interface lock in turn.
loop(8, "autoSkill", function() withUI("skills", buySkills) end)
-- Cheap safety net: verify the best owned weapon is the one in hand.
loop(20, "autoWeapon", function() withUI("weapon check", ensureBestEquipped) end)
loop(45, "cleanPets", function() withUI("pets", cleanPets) end)
-- The game's auto-delete keeps working on its own; this only re-asserts the
-- setting in case a rejoin or a UI reset dropped it.
loop(120, "cleanBag", function()
	if STATE.autoDeleteSet ~= CONFIG.deleteRarity then
		withUI("auto-delete", applyAutoDelete)
	end
end)

task.spawn(function()
	while _G.__LOOTEVO == generation do
		if CONFIG.autoFarm then
			pcall(farmCycle)
		else
			STATE.phase = "idle"
			task.wait(0.5)
		end
		task.wait(0.2)
	end
end)

task.spawn(function()
	while _G.__LOOTEVO == generation do
		pcall(snapshot)
		task.wait(4)
	end
end)

task.spawn(function()
	while _G.__LOOTEVO == generation do
		refreshMode()
		refreshStage()
		refreshEgg()
		local best = bestWeapon(STATE.wins)
		local active = activeStageNumber()

		-- The header line survives the panel being collapsed, so it carries the
		-- four numbers that matter while playing.
		win:SetStatus(string.format("%s wins   %s dmg   stage %s   rb %d   %s",
			shortNumber(STATE.wins), shortNumber(STATE.damage),
			tostring(active or STATE.ladder), STATE.rebirth, STATE.phase))

		weaponLabel:set(string.format("%s  ->  %s",
			STATE.weapon, best and best.name or "-"))

		ladderOut:set({
			"LADDER",
			string.format("  cursor    %d", STATE.ladder),
			string.format("  cleared   %d", STATE.cleared),
			string.format("  blocked   %s",
				STATE.blockedAt > 0 and tostring(STATE.blockedAt) or "-"),
			string.format("  banked    %d/%d", STATE.bankRuns, CONFIG.farmRuns),
			string.format("  last run  %.1fs", STATE.lastClear),
			string.format("  mobs      %d", STATE.mobs),
			"",
			"NOTE",
			"  " .. tostring(STATE.note),
		})

		runOut:set({
			"SESSION",
			string.format("  runs %d   deaths %d   missed %d",
				STATE.runs, STATE.deaths, STATE.missedClaims),
			string.format("  clicks %d   casts %d   chases %d",
				STATE.clicks, STATE.casts, STATE.chases),
			string.format("  wins gained %s", shortNumber(STATE.winsGained)),
			string.format("  rebirths %d", STATE.rebirths),
			"",
			"  ui lock: " .. tostring(STATE.uiOwner),
		})

		liveOut:set({
			"PLAYER",
			string.format("  wins      %s", shortNumber(STATE.wins)),
			string.format("  damage    %s", shortNumber(STATE.damage)),
			string.format("  level     %d%s", STATE.level,
				STATE.needLevel > 0 and (" / " .. STATE.needLevel) or ""),
			string.format("  rebirth   %d", STATE.rebirth),
			"",
			"SPENDING",
			string.format("  reserve   %s", shortNumber(weaponReserve())),
			string.format("  free      %s", shortNumber(spendableWins())),
			string.format("  weapon    %s", STATE.weapon),
			string.format("  next      %s", best and best.name or "-"),
		})

		progressOut:set({
			"PROGRESS",
			string.format("  stage now   %s", tostring(active or "-")),
			string.format("  highest     %d", STATE.cleared),
			string.format("  peak damage %s", shortNumber(STATE.peakDamage)),
			string.format("  auras       %d", STATE.auras),
			string.format("  eggs        %d", STATE.eggsBought),
			string.format("  skills      %d", STATE.skillsBought),
			string.format("  deleted     %d", STATE.deleted),
			string.format("  healed      %d", STATE.healed),
		})

		bagOut:set({
			"INVENTORY",
			string.format("  auto-delete  %s",
				STATE.autoDeleteSet >= 0 and (RARITY_NAMES[STATE.autoDeleteSet] or "off") or "not set"),
			string.format("  deleted      %d", STATE.deleted),
			string.format("  pets cleaned %s",
				STATE.petsCleanedAt >= 0 and "yes" or "no"),
			"",
			"  " .. tostring(STATE.note),
		})

		task.wait(0.5)
	end
	win:Destroy()
end)

_G.__LOOTEVO_DBG = {
	CONFIG = CONFIG, STATE = STATE, unstuck = unstuck,
	weapons = WEAPONS, eggs = EGGS, auras = AURAS,
	cleanPets = cleanPets, cleanBackpack = cleanBackpack, applyAutoDelete = applyAutoDelete,
	buySkills = buySkills, castSkills = castSkills, skillState = skillState,
	buyBestEgg = buyBestEgg, eggIsFinished = eggIsFinished, eggBest = EGG_BEST,
	skillShoppingList = skillShoppingList, weaponUpgradePending = weaponUpgradePending,
	ensureBestEquipped = ensureBestEquipped, canSpend = canSpend,
	resetProgression = resetProgression, tryRebirth = tryRebirth, claimWin = claimWin,
	weaponReserve = weaponReserve, spendableWins = spendableWins,
	ownedPetCount = ownedPetCount, bestOwnedAddition = bestOwnedAddition,
	applyGodMode = applyGodMode, withUI = withUI,
	redeemCodes = redeemCodes, upgradeWeapon = upgradeWeapon, buyBestAura = buyBestAura,
}
CTRL.lastScan = 0   -- a fresh execute always re-resolves the controllers
scanControllers()
snapshot()
STATE.ladder = math.max(1, math.min(STATE.ladder, STATE.cleared + 1))
task.spawn(function()
	if not _G.__LOOTEVO_CODES then
		_G.__LOOTEVO_CODES = true
		redeemCodes()
	end
end)
print("[lootevo] by seltonmt - running (gen " .. generation .. ") - RightShift toggles the UI")
