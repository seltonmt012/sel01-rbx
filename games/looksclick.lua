--[[ looksclick.lua - "[🌎W8] +1 Looks Per Click" (place 102355196524321)

  The loop the game actually runs:

      click -> Looks;  an AutoTrainer adds more Looks on its own while you stand on it
      Looks -> the NPCs you can out-mog;  mogging one pays Wins
      Wins  -> gear, and gear is what a click is WORTH
      Looks -> zones, and further out zones hold NPCs paying thousands of times more
      Rebirth -> stronger AutoTrainers;  eight worlds, each its own Looks wall

  This game speaks **Warp** (imezx_warp 1.0.14), not plain RemoteEvents: all of its
  traffic goes down three remotes and every channel is addressed by a hashed string
  id, so `ReplicatedStorage` looks almost empty. The client side is
  `require(ReplicatedStorage.Packages.warp).Client("<name>")` and the 64 channel
  names were read out of the decompiled controllers. Two consequences worth knowing:

  * The bridge/executor runs at identity 8 and `require` on a normal module fails
    with "Cannot require a non-RobloxScript module from a RobloxScript". Raising the
    thread identity to 2 around BOTH the require AND `warp.Client(...)` is needed -
    Client() loads its own submodules lazily, so wrapping only the require still
    throws.
  * There is no remote to enumerate; the channel list comes from the client source.

  Everything below was measured through the bridge before it was written down:

  * `GainLooks:Fire(true)` is the click and the server rate limits it HARD, and
    firing faster makes it worse: one call per frame (57/s) credited 3.75 looks/s,
    five per frame credited 1.5/s, a 0.5s gap credited 100% of a much smaller
    number. A 0.125s gap is the peak at ~3.75 credited clicks a second.
  * An AutoTrainer is a passive second engine and the two STACK: the x1 Bronze
    trainer alone made 10 looks/s, clicking alone 17/s, and standing on it while
    clicking made 27.5/s. Trainers are chosen by standing in their hitbox, which
    sets the `CurrentTrainer` attribute, and they are gated by rebirth count
    (x2 at 2 rebirths, x20 at 14, up to x113 in the config).
  * A mog is `ContestRequest:Fire(true, <npc model name>)` followed by
    `ContestClick:Fire(true, nil)`. It is **position gated** - from 300 studs the
    contest never starts, standing next to the NPC it always does - and it is over
    in about 0.9 seconds with five clicks whenever your Looks clearly beat the
    NPC's requirement. Four mogs of HumbleMogger (1300 Looks) paid exactly 4 x 325.
  * NPCs are CLIENT-side models in `workspace.ClientNPCs` carrying `NPCType` and
    `ZoneName`, and only the ones near the character exist - so the picker has to
    travel to a zone before it can see what lives there. Asking for an NPC of a
    zone that is out of reach is simply refused, no error.
  * Gear is bought by touching `<model>.ButtonTop` in the world's GearShop and
    `firetouchinterest` reaches it **from 108 studs** - no walking. It is a
    best-only ladder, not a sum: buying the 1-win Comb took `TotalLooksPerClick`
    from 1 to 5 and `BestGearMultiplier` from 0 to 5.

  Never spends Robux: the God Crown, the OP/Rainbow trainers, every `RobuxTier`
  entry, the Robux side of the teleport and rebirth panels and every
  `PromptProductPurchase` path are filtered out by their own fields, never by name.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local plr = Players.LocalPlayer

local GEN = (_G.__LOOKSCLICK or 0) + 1
_G.__LOOKSCLICK = GEN

--------------------------------------------------------------------------------
-- config
--------------------------------------------------------------------------------

local CONFIG = {
	auto = false,
	click = true,           -- GainLooks; the server credits ~3.75/s and no more
	clickGap = 0.125,       -- measured peak; smaller is credited WORSE, not better
	trainer = true,         -- stand on the best AutoTrainer the rebirths allow
	mog = true,             -- travel to the strongest beatable NPC and out-mog it
	gear = true,            -- best affordable gear in this world, touched from afar
	portals = true,         -- take the world portal once its Looks wall is passed
	rebirth = true,         -- Rebirth("Max") - this is what unlocks the trainers
	freebies = true,        -- free spin, group reward, offline earnings, leave gift

	trainSeconds = 30,      -- seconds on the trainer before each mogging trip
	mogSeconds = 45,        -- seconds spent mogging before going back to train
	contestSeconds = 10,    -- give up on one contest after this long
	rebirthUntil = 0,       -- 0 = no limit
}

local STATE = {
	phase = "idle",
	note = "",
	looks = 0, wins = 0, rebirths = 0, tokens = 0,
	looksRate = 0, winsRate = 0,
	perClick = 1, gear = "-", gearMul = 0,
	trainer = "-", trainerMul = 0,
	world = 1, zone = "-",
	npc = "-", npcPays = 0, mogs = 0,
	busy = false, bodyOwner = nil,
}

--------------------------------------------------------------------------------
-- helpers
--------------------------------------------------------------------------------

local function short(n)
	n = tonumber(n) or 0
	local units = {
		{ 1e30, "No" }, { 1e27, "Oc" }, { 1e24, "Sp" }, { 1e21, "Sx" },
		{ 1e18, "Qi" }, { 1e15, "Qa" }, { 1e12, "T" }, { 1e9, "B" },
		{ 1e6, "M" }, { 1e3, "K" },
	}
	for _, u in ipairs(units) do
		if math.abs(n) >= u[1] then return string.format("%.2f%s", n / u[1], u[2]) end
	end
	return string.format("%.0f", n)
end

local function note(text) STATE.note = text end

local function char()
	local model = plr.Character
	if not model then return nil, nil, nil end
	return model, model:FindFirstChild("HumanoidRootPart"), model:FindFirstChildOfClass("Humanoid")
end

-- The executor thread runs at identity 8, where requiring a normal ModuleScript
-- throws "Cannot require a non-RobloxScript module from a RobloxScript". Raise it
-- for the call and put it straight back.
local function asGame(fn, ...)
	local restore = getthreadidentity and getthreadidentity() or nil
	if setthreadidentity then pcall(setthreadidentity, 2) end
	local ok, a, b = pcall(fn, ...)
	if setthreadidentity and restore then pcall(setthreadidentity, restore) end
	if not ok then return nil, a end
	return a, b
end

local moduleCache = {}

local function conf(name)
	if moduleCache[name] ~= nil then return moduleCache[name] end
	local folder = ReplicatedStorage:FindFirstChild("Shared")
	folder = folder and folder:FindFirstChild("Modules")
	local mod = folder and folder:FindFirstChild(name)
	if not mod then return nil end
	local value = asGame(require, mod)
	moduleCache[name] = value
	return value
end

-- warp.Client() loads its own submodules lazily, so it needs the raised identity
-- as well - wrapping only the require still throws.
_G.__LOOKSCLICK_WARP = _G.__LOOKSCLICK_WARP or {}
local warpLib

local function channel(name)
	local cache = _G.__LOOKSCLICK_WARP
	if cache[name] then return cache[name] end
	if not warpLib then
		warpLib = asGame(require, ReplicatedStorage:WaitForChild("Packages"):WaitForChild("warp"))
	end
	if not warpLib then return nil end
	local client = asGame(function() return warpLib.Client(name) end)
	cache[name] = client
	return client
end

local function fire(name, ...)
	local c = channel(name)
	if not c then return false end
	local args = { ... }
	return (pcall(function() c:Fire(table.unpack(args)) end))
end

local function pin(getCFrame)
	local stop = false
	local conn
	conn = RunService.Heartbeat:Connect(function()
		if stop or GEN ~= _G.__LOOKSCLICK then conn:Disconnect() return end
		local _, hrp = char()
		local cf = getCFrame()
		if hrp and cf then hrp.CFrame = cf end
	end)
	return function()
		stop = true
		pcall(function() conn:Disconnect() end)
	end
end

local function withBody(name, fn)
	if STATE.bodyOwner then return false, "busy" end
	STATE.bodyOwner = name
	local ok, err = pcall(fn)
	STATE.bodyOwner = nil
	if not ok then note(name .. " failed: " .. tostring(err)) end
	return ok, err
end

local function loop(sec, key, fn)
	task.spawn(function()
		while GEN == _G.__LOOKSCLICK do
			if CONFIG.auto and (key == nil or CONFIG[key]) then
				local ok, err = pcall(fn)
				if not ok then note(tostring(key) .. " failed: " .. tostring(err)) end
			end
			task.wait(sec)
		end
	end)
end

local function stat(name, default)
	local ls = plr:FindFirstChild("leaderstats")
	local v = ls and ls:FindFirstChild(name)
	return v and v.Value or default
end

--------------------------------------------------------------------------------
-- state
--------------------------------------------------------------------------------

local lastLooks, lastWins, lastSample = 0, 0, 0

local function refresh()
	STATE.looks = stat("Looks", 0)
	STATE.wins = stat("Wins", 0)
	STATE.rebirths = stat("Rebirths", 0)
	STATE.tokens = stat("FameTokens", 0)
	STATE.perClick = plr:GetAttribute("TotalLooksPerClick") or 1
	STATE.gearMul = plr:GetAttribute("BestGearMultiplier") or 0
	STATE.trainer = plr:GetAttribute("CurrentTrainer")
	if STATE.trainer == nil or STATE.trainer == "" then STATE.trainer = "-" end
	STATE.world = plr:GetAttribute("CurrentWorld") or 1

	local now = os.clock()
	if lastSample > 0 and now - lastSample >= 1 then
		local dt = now - lastSample
		if STATE.looks >= lastLooks then STATE.looksRate = (STATE.looks - lastLooks) / dt end
		if STATE.wins >= lastWins then STATE.winsRate = (STATE.wins - lastWins) / dt end
	end
	if now - lastSample >= 1 then
		lastLooks, lastWins, lastSample = STATE.looks, STATE.wins, now
	end
end

--------------------------------------------------------------------------------
-- the click engine
--
-- One timed loop rather than a Heartbeat connection, because this is the one
-- clicker in the repo where firing FASTER credits LESS: 57 calls/s credited
-- 3.75 looks/s, 300 calls/s credited 1.5, and a 0.125s gap sits at the peak.
--------------------------------------------------------------------------------

task.spawn(function()
	while GEN == _G.__LOOKSCLICK do
		if CONFIG.auto and CONFIG.click then
			pcall(fire, "GainLooks", true)
		end
		task.wait(math.max(0.05, CONFIG.clickGap))
	end
end)

--------------------------------------------------------------------------------
-- the trainer: a passive second Looks engine that stacks with clicking
--------------------------------------------------------------------------------

local function worldFolder(index)
	return workspace:FindFirstChild("World" .. tostring(index or STATE.world or 1))
end

local function pivotOf(instance)
	if not instance then return nil end
	if instance:IsA("BasePart") then return instance.Position end
	local ok, cf = pcall(function() return instance:GetPivot() end)
	return ok and cf.Position or nil
end

-- Trainers are gated by rebirth count and the Robux ones carry RequiredPass /
-- RobuxTier, which is the field to filter on - "OPTrainer" would otherwise read
-- as just another entry.
local function bestTrainer()
	local cfg = conf("AutoTrainerConfig") or {}
	local folder = worldFolder()
	folder = folder and folder:FindFirstChild("AutoTrainers")
	if not folder then return nil end
	local best, bestMul
	for _, model in ipairs(folder:GetChildren()) do
		local entry = cfg[model.Name]
		local mul = entry and tonumber(entry.Multiplier)
		local paid = entry and (entry.RequiredPass or entry.RobuxTier)
		local need = entry and tonumber(entry.RequiredRebirths) or 0
		if mul and not paid and STATE.rebirths >= need then
			if not bestMul or mul > bestMul then best, bestMul = model, mul end
		end
	end
	return best, bestMul
end

local function trainPhase()
	local model, mul = bestTrainer()
	if not model then return end
	local pos = pivotOf(model)
	if not pos then return end
	STATE.trainerMul = mul or 0
	STATE.phase = "training x" .. tostring(mul)
	local target = CFrame.new(pos + Vector3.new(0, 4, 0))
	local stop = pin(function() return target end)
	local deadline = os.clock() + CONFIG.trainSeconds
	while os.clock() < deadline and GEN == _G.__LOOKSCLICK
		and CONFIG.auto and CONFIG.trainer do
		task.wait(0.3)
		STATE.trainer = plr:GetAttribute("CurrentTrainer") or STATE.trainer
	end
	stop()
end

--------------------------------------------------------------------------------
-- mogging: the Wins engine
--------------------------------------------------------------------------------

-- The zone to stand in is the furthest one this world offers whose RequiredLooks
-- we have passed; its NPCs only exist once the character is near them.
local function bestZone()
	local zones = conf("ZoneConfig") or {}
	local folder = worldFolder()
	folder = folder and folder:FindFirstChild("ZoneGrounds")
	if not folder then return nil end
	local best, bestNeed
	for name, entry in pairs(zones) do
		local need = tonumber(entry and entry.RequiredLooks)
		local ground = entry and entry.Ground and folder:FindFirstChild(entry.Ground)
		local world = tonumber(entry and entry.World) or 1
		if need and ground and world == STATE.world and need <= STATE.looks then
			if not bestNeed or need > bestNeed then best, bestNeed = ground, need end
		end
	end
	return best, bestNeed
end

-- Strongest NPC in reach that our Looks actually beat. Ranking on the payout
-- rather than on the requirement, because the two are not in the same order for
-- every entry in the table.
local function bestNPC()
	local cfg = conf("NPCsConfig") or {}
	local folder = workspace:FindFirstChild("ClientNPCs")
	if not folder then return nil end
	local best, bestEntry
	for _, model in ipairs(folder:GetChildren()) do
		local entry = cfg[model.Name]
		local need = entry and tonumber(entry.Looks)
		local pays = entry and tonumber(entry.Wins)
		if need and pays and need <= STATE.looks and model:FindFirstChild("HumanoidRootPart") then
			if not bestEntry or pays > tonumber(bestEntry.Wins) then best, bestEntry = model, entry end
		end
	end
	return best, bestEntry
end

local function mogOnce(model)
	local root = model:FindFirstChild("HumanoidRootPart")
	if not root then return false end
	local target = CFrame.new(root.Position + Vector3.new(0, 0, 5))
	local stop = pin(function() return target end)
	task.wait(0.35)
	fire("ContestRequest", true, model.Name)
	local deadline = os.clock() + 2
	repeat task.wait(0.1) until plr:GetAttribute("InContest") or os.clock() > deadline
	if not plr:GetAttribute("InContest") then
		stop()
		return false
	end
	local limit = os.clock() + CONFIG.contestSeconds
	repeat
		fire("ContestClick", true, nil)
		task.wait(0.06)
	until not plr:GetAttribute("InContest") or os.clock() > limit
	stop()
	return true
end

local function mogPhase()
	local ground, need = bestZone()
	if ground then
		STATE.zone = ground.Name .. " (" .. short(need or 0) .. ")"
		-- stand on the zone first so its NPCs stream in; they are client models
		local target = CFrame.new(ground.Position + Vector3.new(0, 6, 0))
		local stop = pin(function() return target end)
		task.wait(1.2)
		stop()
	end
	local deadline = os.clock() + CONFIG.mogSeconds
	while os.clock() < deadline and GEN == _G.__LOOKSCLICK and CONFIG.auto and CONFIG.mog do
		refresh()
		local model, entry = bestNPC()
		if not model then
			note("no beatable NPC in reach - training instead")
			return
		end
		STATE.npc = model.Name
		STATE.npcPays = tonumber(entry.Wins) or 0
		STATE.phase = "mogging " .. model.Name
		if mogOnce(model) then
			STATE.mogs = STATE.mogs + 1
		else
			task.wait(0.5)
		end
		task.wait(0.15)
	end
end

--------------------------------------------------------------------------------
-- spending
--------------------------------------------------------------------------------

-- Gear is a best-only ladder and the shop model's ButtonTop is a TouchInterest
-- that answers from 108 studs, so this never moves the character.
local function gearPass()
	local cfg = conf("GearConfig") or {}
	local shop = worldFolder()
	shop = shop and shop:FindFirstChild("GearShop")
	if not shop then return end
	local _, hrp = char()
	if not hrp then return end
	local best, bestEntry
	for _, model in ipairs(shop:GetChildren()) do
		local entry = cfg[model.Name]
		local cost = entry and tonumber(entry.Cost)
		local mul = entry and tonumber(entry.Multiplier)
		-- entries without a numeric Cost are the Robux ones (God Crown)
		if cost and mul and not entry.Premium and cost <= STATE.wins
			and mul > (STATE.gearMul or 0) then
			if not bestEntry or mul > tonumber(bestEntry.Multiplier) then
				best, bestEntry = model, entry
			end
		end
	end
	if not best then return end
	local button
	for _, d in ipairs(best:GetDescendants()) do
		if d:IsA("BasePart") and d.Name == "ButtonTop" then button = d break end
	end
	if not button then return end
	local before = plr:GetAttribute("BestGearMultiplier") or 0
	pcall(function()
		firetouchinterest(hrp, button, 0)
		task.wait(0.15)
		firetouchinterest(hrp, button, 1)
	end)
	task.wait(1)
	local after = plr:GetAttribute("BestGearMultiplier") or before
	if after > before then
		STATE.gear = bestEntry.Name or best.Name
		STATE.gearMul = after
		note(string.format("gear %s x%s (%s wins)", STATE.gear, short(after), short(tonumber(bestEntry.Cost))))
	end
end

-- "Max" converts everything affordable in one call, which is also what the panel
-- button does. Rebirths are the only thing that unlocks the stronger trainers.
local function rebirthPass()
	if CONFIG.rebirthUntil > 0 and STATE.rebirths >= CONFIG.rebirthUntil then return end
	local before = STATE.rebirths
	fire("Rebirth", true, "Max")
	task.wait(1.5)
	refresh()
	if STATE.rebirths > before then
		note(string.format("rebirth %s -> %s", short(before), short(STATE.rebirths)))
	end
end

-- Worlds are walls of Looks, and the portal is a model in this world's
-- TravelPortals folder. UsePortal takes the world NUMBER.
local function portalPass()
	local cfg = conf("WorldConfig") or {}
	local nextWorld = (STATE.world or 1) + 1
	if nextWorld > 8 then return end
	local need = tonumber(cfg["World" .. nextWorld .. "Requirement"])
	if not need or STATE.looks < need then return end
	local folder = worldFolder()
	folder = folder and folder:FindFirstChild("TravelPortals")
	local model = folder and folder:FindFirstChild("World" .. nextWorld .. "Portal")
	local pos = pivotOf(model)
	if not pos then return end
	withBody("portal", function()
		STATE.phase = "portal to world " .. nextWorld
		local target = CFrame.new(pos)
		local stop = pin(function() return target end)
		task.wait(1)
		fire("UsePortal", true, nextWorld)
		task.wait(2)
		stop()
		refresh()
		note("world " .. tostring(STATE.world))
	end)
end

local function freePass()
	fire("ClaimFreeSpin", true)
	task.wait(0.4)
	if (plr:GetAttribute("Spins") or 0) > 0 then
		fire("SpinWheel", true)
		task.wait(0.6)
	end
	if not plr:GetAttribute("GroupRewardClaimed") then
		fire("ClaimGroupReward", true)
		task.wait(0.4)
	end
	fire("OfflineEarningsClaim", true)
	task.wait(0.3)
	if plr:GetAttribute("LeaveRewardReady") then
		fire("LeaveRewardClaimed", true)
	end
	fire("ClaimRebirthTokens", true)
end

local function spendPass()
	if CONFIG.gear then gearPass() end
	if CONFIG.rebirth then rebirthPass() end
	if CONFIG.portals then portalPass() end
end

--------------------------------------------------------------------------------
-- the cycle
--------------------------------------------------------------------------------

local function cyclePass()
	if STATE.bodyOwner then return end
	withBody("cycle", function()
		if CONFIG.trainer then trainPhase() end
		if CONFIG.mog then mogPhase() end
	end)
end

task.spawn(function()
	while GEN == _G.__LOOKSCLICK do
		pcall(refresh)
		task.wait(0.5)
	end
end)

loop(0.4, nil, cyclePass)
loop(8, nil, spendPass)
loop(90, "freebies", freePass)

--------------------------------------------------------------------------------
-- panel
--------------------------------------------------------------------------------

local UI = (_G.__SEL and _G.__SEL.ui) or loadstring(readfile("ui-template.lua"))()
if _G.__LOOKSCLICK_WIN then pcall(function() _G.__LOOKSCLICK_WIN:Destroy() end) end
for _, root in ipairs({ (gethui and gethui()) or nil, game:GetService("CoreGui") }) do
	if root then
		for _, g in ipairs(root:GetChildren()) do
			if g.Name == "LooksClickPanel" then pcall(function() g:Destroy() end) end
		end
	end
end

local win = UI.Window({
	name = "LooksClickPanel",
	title = "LOOKS", accentTitle = "CLICK", subtitle = "seltonmt",
	badge = "🌎", width = 920, height = 580,
})
_G.__LOOKSCLICK_WIN = win

local page = win:Page("FARM", UI.icon.bolt)

local main = page:Card("LOOP", 1)
main:Toggle("AUTO", CONFIG.auto, function(v)
	CONFIG.auto = v
	note(v and "running" or "stopped")
end, "train, mog, buy gear, rebirth, repeat", UI.theme.good)
main:Toggle("Click", CONFIG.click, function(v) CONFIG.click = v end,
	"the server credits ~3.75/s; firing faster credits LESS, not more")
main:Toggle("Auto trainer", CONFIG.trainer, function(v) CONFIG.trainer = v end,
	"passive looks that stack with clicking, gated by rebirths")
main:Toggle("Mog NPCs", CONFIG.mog, function(v) CONFIG.mog = v end,
	"travels to the strongest NPC your looks beat; the contest is position gated")
main:Stepper("Train for", function() return CONFIG.trainSeconds .. "s" end, function(dir)
	CONFIG.trainSeconds = math.clamp(CONFIG.trainSeconds + dir * 10, 0, 300)
end, "seconds on the trainer before each mogging trip")
main:Stepper("Mog for", function() return CONFIG.mogSeconds .. "s" end, function(dir)
	CONFIG.mogSeconds = math.clamp(CONFIG.mogSeconds + dir * 15, 15, 600)
end, "seconds spent mogging before going back to the trainer")

local spend = page:Card("SPENDING", 2)
spend:Toggle("Buy gear", CONFIG.gear, function(v) CONFIG.gear = v end,
	"best affordable in this world, touched from anywhere; best-only, not a sum",
	UI.theme.warn)
spend:Toggle("Auto rebirth", CONFIG.rebirth, function(v) CONFIG.rebirth = v end,
	"Rebirth(\"Max\") - the only thing that unlocks stronger trainers", UI.theme.warn)
spend:Stepper("Rebirth until", function()
	return CONFIG.rebirthUntil == 0 and "no limit" or short(CONFIG.rebirthUntil)
end, function(dir)
	CONFIG.rebirthUntil = math.clamp(CONFIG.rebirthUntil + dir * 25, 0, 100000)
end, "stop rebirthing at this count")
spend:Toggle("Take portals", CONFIG.portals, function(v) CONFIG.portals = v end,
	"moves on to the next world once its looks wall is passed", UI.theme.warn)
spend:Toggle("Free rewards", CONFIG.freebies, function(v) CONFIG.freebies = v end,
	"free spin, group reward, offline earnings, leave gift", UI.theme.good)
spend:Button("Unstuck", function()
	CONFIG.auto = false
	STATE.bodyOwner = nil
	local _, _, hum = char()
	if hum then pcall(function() hum.PlatformStand = false hum.WalkSpeed = 16 end) end
	note("unstuck, auto off")
end, UI.theme.bad)

local out = page:Card("STATUS", 0):Readout(12, function(text)
	if text:find("^AUTO") then return UI.theme.good end
	return nil
end)

task.spawn(function()
	while GEN == _G.__LOOKSCLICK do
		local lines = {
			CONFIG.auto and "AUTO RUNNING" or "STOPPED",
			"  phase     " .. tostring(STATE.phase),
			"  looks     " .. short(STATE.looks) .. "   " .. short(STATE.looksRate) .. "/s",
			"  per click " .. short(STATE.perClick) .. "   gear x" .. short(STATE.gearMul),
			"  wins      " .. short(STATE.wins) .. "   " .. short(STATE.winsRate) .. "/s",
			"  gear      " .. tostring(STATE.gear),
			"  trainer   " .. tostring(STATE.trainer) .. "   x" .. tostring(STATE.trainerMul),
			"  world     " .. tostring(STATE.world) .. "   " .. tostring(STATE.zone),
			"  npc       " .. tostring(STATE.npc) .. "   pays " .. short(STATE.npcPays),
			"  mogs      " .. STATE.mogs,
			"  rebirths  " .. short(STATE.rebirths) .. "   tokens " .. short(STATE.tokens),
			"  " .. tostring(STATE.note),
		}
		pcall(function() out:set(lines) end)
		pcall(function()
			win:SetStatus(string.format("%s looks   %s wins   reb %s   W%s   %s",
				short(STATE.looks), short(STATE.wins), short(STATE.rebirths),
				tostring(STATE.world), STATE.phase))
		end)
		task.wait(0.5)
	end
end)

win:Refresh()

--------------------------------------------------------------------------------

_G.__LOOKSCLICK_DBG = {
	CONFIG = CONFIG, STATE = STATE,
	refresh = refresh, short = short, pin = pin, conf = conf,
	channel = channel, fire = fire, asGame = asGame,
	bestTrainer = bestTrainer, trainPhase = trainPhase,
	bestZone = bestZone, bestNPC = bestNPC, mogOnce = mogOnce, mogPhase = mogPhase,
	gearPass = gearPass, rebirthPass = rebirthPass, portalPass = portalPass,
	freePass = freePass, spendPass = spendPass, cyclePass = cyclePass,
	worldFolder = worldFolder,
}

print("[looksclick] gen " .. GEN .. " ready - RightShift for the panel")
