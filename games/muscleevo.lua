--!nocheck
-- muscleevo.lua  --  "[UPD] +1 Muscle Evolution"  (place 133007106457547)
--
-- Clicker/idle RPG. Clicking raises Strength, Strength raises Level, Level allows
-- a Rebirth, a Rebirth multiplies everything and unlocks a stronger training bag.
-- Wins come from claim pads inside the stages and buy body evolutions.
--
-- The game is a Knit-ish client with everything in ReplicatedStorage.Client and
-- 92 config modules under Shared.Configs, all require-able, so nothing had to be
-- captured off the wire. Traffic itself is useless to watch: it is multiplexed
-- through PlayerReplicator/ServerReplicator as compressed buffers.
--
-- Measured, against ClientData.Profile.DataAccessor:GetData() (the state oracle -
-- Strength, Wins, Rebirth, Currency, EquippedBody, OwnedBodies, WorldProgress):
--
--   * ClickController:FireAutoClick() is the click. +1 Strength per accepted call.
--   * Configs.Clicks.ClickCooldown is 0.01, so the server permits 100 a second.
--     Measured: 8 calls/s -> 7.6 Strength/s, 30/s -> 21.6, 90/s -> 40.4. The free
--     auto clicker does 5/s and the Robux one 15/s, so driving it directly is
--     roughly 7x the free tool and nearly 3x the paid one.
--   * More than one call per frame is wasted: 1, 2 and 4 per Heartbeat all landed
--     on ~36/s. One per Heartbeat already saturates the server's cooldown.
--   * Training bags are plain multipliers gated on rebirths, read straight off the
--     tagged instance: x1 free, x2 at 1, x5 at 5, x15 at 10, x35 at 15, x80 at 20.
--     x10 is the VIP gamepass and x25/x100/x999 are DevProducts - all skipped.
--
-- No anti-cheat exists here: no warning remote, no audit flags, no position
-- checks. The only limiter is the click cooldown above.
--
-- Never touched, all Robux: the x25/x100/x999 bags, the VIP bag, OP Auto Clicker,
-- every "2x Wins" claim pad (Configs.WinButtons.DoubleWinsModelNames), chests,
-- gifts and every PromptPurchase path.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local CollectionService = game:GetService("CollectionService")
local ProximityPromptService = game:GetService("ProximityPromptService")

local plr = Players.LocalPlayer

local Shared = ReplicatedStorage.Shared
local Client = ReplicatedStorage.Client
local ClientData = require(Client.Controllers.ClientData)
local ClickController = require(Client.Controllers.GameBased.ClickController)
local CfgRebirth = require(Shared.Configs.Rebirth)
local CfgWinButtons = require(Shared.Configs.WinButtons)
local CfgStrengthLevels = require(Shared.Configs.StrengthLevels)

--------------------------------------------------------------------------------
-- config / state
--------------------------------------------------------------------------------

local CONFIG = {
	auto = false,
	click = true,          -- FireAutoClick every Heartbeat
	trainZone = true,      -- stand in the strongest bag the rebirth count allows
	rebirth = true,
	-- Off by default and honestly so: a tour of twelve pads was walked and Wins
	-- never moved off zero. The pads sit inside the stages (Worlds.World_1.Stages.
	-- Stage_001.Wins) and almost certainly want the stage cleared first, which is
	-- not built yet. Leaving it on only steals time from the bag.
	claimWins = false,
	buyBody = true,        -- buy the best affordable evolution
	moveSpeed = 90,
	claimEvery = 45,       -- seconds between win-pad tours
	maxClaimTravel = 900,  -- studs; further pads are on another stage entirely
}

local STATE = {
	note = "idle",
	phase = "-",
	strength = 0,
	level = 0,
	rebirths = 0,
	wins = 0,
	currency = 0,
	zone = "-",
	zoneMulti = 0,
	body = "-",
	rate = 0,
	lastStrength = 0,
	lastAt = 0,
	claims = 0,
	nextClaimAt = 0,
	busy = false,
}

_G.__MUSCLE = (_G.__MUSCLE or 0) + 1
local GEN = _G.__MUSCLE

--------------------------------------------------------------------------------
-- helpers
--------------------------------------------------------------------------------

local function short(n)
	if type(n) ~= "number" then return "?" end
	local units = { "", "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp" }
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

local function data()
	local ok, d = pcall(function()
		return ClientData.Profile.DataAccessor:GetData()
	end)
	return ok and type(d) == "table" and d or nil
end

local function levelOf(strength)
	local ok, info = pcall(function() return CfgStrengthLevels.GetLevelInfo(strength) end)
	if ok and type(info) == "table" then
		return tonumber(info.Level) or tonumber(info.level) or 0
	end
	if ok and tonumber(info) then return tonumber(info) end
	return 0
end

local function hop(goal, extra)
	local _, hrp = char()
	if not hrp or not goal then return false end
	local dist = (goal - hrp.Position).Magnitude
	if dist < 4 then return true end
	local dur = math.max(dist / math.max(CONFIG.moveSpeed, 10), 0.1)
	TweenService:Create(hrp, TweenInfo.new(dur, Enum.EasingStyle.Linear),
		{ CFrame = CFrame.new(goal) }):Play()
	task.wait(dur + (extra or 0.35))
	return true
end

--------------------------------------------------------------------------------
-- training bags
--------------------------------------------------------------------------------

-- Every bag carries its own multiplier and its own gate as attributes, so the
-- choice is read from the world rather than from a table that could drift:
-- Multiplier, RequiredRebirths, and - the ones to avoid - DevProductId,
-- RequiredGamepassId and AdminOnly.
local function bestTrainZone()
	local d = data()
	local rebirths = d and tonumber(d.Rebirth) or 0
	local best, bestMulti
	for _, z in ipairs(CollectionService:GetTagged("TrainZone")) do
		local multi = tonumber(z:GetAttribute("Multiplier")) or 0
		local needs = tonumber(z:GetAttribute("RequiredRebirths")) or 0
		local paid = z:GetAttribute("DevProductId") or z:GetAttribute("RequiredGamepassId")
		local admin = z:GetAttribute("AdminOnly") or z:GetAttribute("AdminBag")
		if not paid and not admin and rebirths >= needs then
			if not bestMulti or multi > bestMulti then best, bestMulti = z, multi end
		end
	end
	return best, bestMulti or 0
end

local function standInZone()
	if not CONFIG.trainZone then return end
	local zone, multi = bestTrainZone()
	if not zone then return end
	STATE.zoneMulti = multi
	STATE.zone = "x" .. multi
	local ok, pivot = pcall(function() return zone:GetPivot() end)
	if not ok then return end
	local _, hrp = char()
	if not hrp then return end
	if (pivot.Position - hrp.Position).Magnitude > 6 then
		STATE.phase = "to bag x" .. multi
		hop(pivot.Position + Vector3.new(0, 3, 0))
	end
end

--------------------------------------------------------------------------------
-- clicking
--------------------------------------------------------------------------------

-- One call per Heartbeat. Two and four per frame were measured at the same
-- ~36/s, so anything beyond one is thrown away by the server's 0.01s cooldown.
local clickConn
local function startClicking()
	if clickConn then clickConn:Disconnect() end
	clickConn = RunService.Heartbeat:Connect(function()
		if GEN ~= _G.__MUSCLE then clickConn:Disconnect() return end
		if not (CONFIG.auto and CONFIG.click) then return end
		pcall(function() ClickController:FireAutoClick() end)
	end)
end

--------------------------------------------------------------------------------
-- wins
--------------------------------------------------------------------------------

-- The pads live inside the stages and pay the amount written on the model. The
-- "2x Wins" twins are the Robux doubles and are filtered by name, not by price.
local function isDoublePad(model)
	local names = CfgWinButtons.DoubleWinsModelNames or { "x2 Wins", "2x Wins" }
	for _, n in ipairs(names) do
		if model.Name == n then return true end
	end
	return model.Name:find("2x") ~= nil or model.Name:find("x2") ~= nil
end

local function claimWins()
	if not CONFIG.claimWins then return false end
	local _, hrp = char()
	if not hrp then return false end
	local origin = hrp.Position

	local pads = {}
	for _, model in ipairs(CollectionService:GetTagged("WinButton")) do
		if not isDoublePad(model) then
			local claim = model:FindFirstChild(CfgWinButtons.ClaimPartName or "Claim Part")
			if claim and claim:IsA("BasePart") then
				local dist = (claim.Position - origin).Magnitude
				if dist <= CONFIG.maxClaimTravel then
					pads[#pads + 1] = {
						part = claim,
						wins = tonumber(model:GetAttribute("Wins")) or 0,
						dist = dist,
					}
				end
			end
		end
	end
	if #pads == 0 then return false end
	-- richest first, and the tour stops as soon as the cycle needs the body back
	table.sort(pads, function(a, b) return a.wins > b.wins end)

	STATE.phase = "claim wins"
	local claimed = 0
	for index, pad in ipairs(pads) do
		if index > 12 or not CONFIG.auto or GEN ~= _G.__MUSCLE then break end
		hop(pad.part.Position + Vector3.new(0, 3, 0), 0.3)
		if firetouchinterest then
			pcall(firetouchinterest, pad.part, hrp, 0)
			task.wait(0.1)
			pcall(firetouchinterest, pad.part, hrp, 1)
		end
		claimed = claimed + 1
		-- ClaimCooldown is 1.5s per pad, so anything faster is wasted travel
		task.wait(math.max(CfgWinButtons.ClaimCooldown or 1.5, 0.5))
	end
	STATE.claims = STATE.claims + claimed
	if claimed > 0 then STATE.note = "toured " .. claimed .. " win pads" end
	return claimed > 0
end

--------------------------------------------------------------------------------
-- evolutions
--------------------------------------------------------------------------------

-- Bodies are bought at a BodyStand's ProximityPrompt, priced in Wins - the prompt
-- itself spells the price out ("450 Wins", "12K Wins"). The game already computes
-- which one the balance covers and publishes it as BestAffordableBodyId, so the
-- pick does not have to re-derive the ladder.
local function buyBestBody()
	if not CONFIG.buyBody then return false end
	local d = data()
	if not d then return false end
	local want = tonumber(d.BestAffordableBodyId)
	local have = tonumber(d.EquippedBody)
	if not want or want == have then return false end

	for _, stand in ipairs(CollectionService:GetTagged("BodyStand")) do
		if tonumber(stand:GetAttribute("BodyId")) == want then
			local prompt = stand:FindFirstChildWhichIsA("ProximityPrompt", true)
			if prompt then
				STATE.phase = "evolve " .. want
				local part = prompt.Parent
				if part and part:IsA("BasePart") then
					hop(part.Position + Vector3.new(0, 3, 3), 0.5)
				end
				pcall(function() fireproximityprompt(prompt) end)
				task.wait(1)
				local after = data()
				if after and tonumber(after.EquippedBody) == want then
					STATE.note = "evolved to body " .. want
					return true
				end
				STATE.note = "body " .. want .. " prompt did not take"
			end
			return false
		end
	end
	return false
end

--------------------------------------------------------------------------------
-- rebirth
--------------------------------------------------------------------------------

local function rebirthReady()
	local d = data()
	if not d then return false end
	local entry = CfgRebirth[(tonumber(d.Rebirth) or 0) + 1]
	if not entry or type(entry.Requirements) ~= "table" then return false end
	local level = levelOf(d.Strength or 0)
	for _, req in ipairs(entry.Requirements) do
		if req.Kind == "Level" and level < (tonumber(req.Amount) or math.huge) then
			return false, req.Amount
		end
	end
	return true
end

-- Rebirth is a UI button, not a world prompt - searching the workspace for one
-- found nothing at all. It sits at Rebirth.Canvas.Content.Content.BottomButtons,
-- next to a SkipRebirth twin that is the Robux shortcut and must never be hit.
-- Fired through the game's own Activated handler rather than by guessing a remote.
local function rebirthButton()
	local gui = plr.PlayerGui:FindFirstChild("Rebirth")
	local canvas = gui and gui:FindFirstChild("Canvas", true)
	local holder = canvas and canvas:FindFirstChild("BottomButtons", true)
	if not holder then return nil end
	for _, b in ipairs(holder:GetChildren()) do
		-- exact name only: "SkipRebirth" also contains "Rebirth"
		if b:IsA("TextButton") and b.Name == "Rebirth" then return b end
	end
	return nil
end

local function doRebirth()
	if not CONFIG.rebirth then return false end
	if not rebirthReady() then return false end

	local button = rebirthButton()
	if not button then
		STATE.note = "rebirth button not found"
		return false
	end

	local before = (data() or {}).Rebirth or 0
	STATE.phase = "rebirth"

	-- The panel has to be showing before the handler does anything, and firing
	-- Activated alone was not enough - the button carries one connection on each of
	-- Down, Up, Click and Activated, and only the full press sequence went through.
	local gui = plr.PlayerGui:FindFirstChild("Rebirth")
	local canvas = gui and gui:FindFirstChild("Canvas")
	local wasVisible = canvas and canvas.Visible
	if canvas then canvas.Visible = true end
	task.wait(0.5)

	local fired = false
	for _, event in ipairs({ "MouseButton1Down", "MouseButton1Up", "MouseButton1Click", "Activated" }) do
		local ok, conns = pcall(function() return getconnections(button[event]) end)
		if ok then
			for _, conn in ipairs(conns) do
				pcall(function() conn:Fire() end)
				fired = true
			end
		end
		task.wait(0.25)
	end
	if canvas and not wasVisible then canvas.Visible = false end
	if not fired then
		STATE.note = "rebirth button has no handler"
		return false
	end
	task.wait(2)
	local after = (data() or {}).Rebirth or 0
	if after > before then
		STATE.note = "rebirth " .. after .. " done"
		return true
	end
	STATE.note = "rebirth refused"
	return false
end

--------------------------------------------------------------------------------
-- loops
--------------------------------------------------------------------------------

local function loop(interval, fn)
	task.spawn(function()
		while GEN == _G.__MUSCLE do
			if CONFIG.auto then
				local ok, err = pcall(fn)
				if not ok then STATE.note = tostring(err) end
			end
			task.wait(interval)
		end
	end)
end

loop(1, function()
	if STATE.busy then return end
	STATE.busy = true
	local ok, err = pcall(function()
		if doRebirth() then return end
		if buyBestBody() then return end
		if os.clock() >= STATE.nextClaimAt then
			STATE.nextClaimAt = os.clock() + math.max(CONFIG.claimEvery, 15)
			if claimWins() then return end
		end
		standInZone()
		STATE.phase = "training " .. STATE.zone
	end)
	STATE.busy = false
	if not ok then STATE.note = tostring(err) end
end)

loop(4, function()
	local d = data()
	if not d then return end
	STATE.strength = tonumber(d.Strength) or 0
	STATE.wins = tonumber(d.Wins) or 0
	STATE.currency = tonumber(d.Currency) or 0
	STATE.rebirths = tonumber(d.Rebirth) or 0
	STATE.level = levelOf(STATE.strength)
	STATE.body = tostring(d.EquippedBody) .. " (best " .. tostring(d.BestAffordableBodyId) .. ")"
	local now = os.clock()
	if STATE.lastAt > 0 and now > STATE.lastAt then
		local rate = (STATE.strength - STATE.lastStrength) / (now - STATE.lastAt)
		if rate >= 0 then STATE.rate = rate end
	end
	STATE.lastStrength, STATE.lastAt = STATE.strength, now
end)

startClicking()

--------------------------------------------------------------------------------
-- panel
--------------------------------------------------------------------------------

local UI = (_G.__SEL and _G.__SEL.ui) or loadstring(readfile("ui-template.lua"))()
if _G.__MUSCLE_WIN then pcall(function() _G.__MUSCLE_WIN:Destroy() end) end

local win = UI.Window({
	title = "MUSCLE", accentTitle = "EVO", subtitle = "seltonmt",
	badge = "💪", width = 920, height = 580,
})
_G.__MUSCLE_WIN = win

local page = win:Page("TRAIN", UI.icon.bolt)

local main = page:Card("LOOP", 1)
main:Toggle("AUTO", CONFIG.auto, function(v)
	CONFIG.auto = v
	STATE.note = v and "running" or "stopped"
end, "click, train, claim, evolve, rebirth", UI.theme.good)
main:Toggle("Click", CONFIG.click, function(v) CONFIG.click = v end,
	"one FireAutoClick per frame; the server caps it at ~36/s")
main:Toggle("Best training bag", CONFIG.trainZone, function(v) CONFIG.trainZone = v end,
	"strongest bag the rebirth count allows, Robux and VIP bags skipped")
main:Toggle("Auto rebirth", CONFIG.rebirth, function(v) CONFIG.rebirth = v end,
	"resets for x2/x3/x4 on strength, money and damage", UI.theme.warn)

local extra = page:Card("WINS & BODIES", 2)
extra:Toggle("Claim win pads", CONFIG.claimWins, function(v) CONFIG.claimWins = v end,
	"tours the richest reachable pads, never the 2x Robux twins")
extra:Toggle("Buy evolutions", CONFIG.buyBody, function(v) CONFIG.buyBody = v end,
	"uses the game's own BestAffordableBodyId", UI.theme.warn)
extra:Stepper("Claim every", function() return CONFIG.claimEvery .. "s" end,
	function(dir) CONFIG.claimEvery = math.clamp(CONFIG.claimEvery + dir * 15, 15, 300) end,
	"how often to leave the bag for a win tour")
extra:Slider("Move speed", 30, 200, CONFIG.moveSpeed, function(v)
	CONFIG.moveSpeed = math.floor(v)
end, "studs per second")
extra:Button("Unstuck", function()
	CONFIG.auto = false
	STATE.busy = false
	STATE.note = "unstuck, auto off"
end, UI.theme.bad)

local out = page:Card("STATUS", 0):Readout(11, function(text)
	if text:find("^AUTO") then return UI.theme.good end
	return nil
end)

task.spawn(function()
	while GEN == _G.__MUSCLE do
		local ready, need = rebirthReady()
		local lines = {
			CONFIG.auto and "AUTO RUNNING" or "STOPPED",
			"  phase    " .. tostring(STATE.phase),
			"  strength " .. short(STATE.strength) .. "   " .. short(STATE.rate) .. "/s",
			"  level    " .. STATE.level .. (ready and "   REBIRTH READY"
				or (need and ("   rebirth at " .. need) or "")),
			"  rebirth  " .. STATE.rebirths .. "   bag " .. tostring(STATE.zone),
			"  wins     " .. short(STATE.wins) .. "   money " .. short(STATE.currency),
			"  body     " .. tostring(STATE.body),
			"  claims   " .. STATE.claims .. " pads this session",
			"  " .. tostring(STATE.note),
		}
		pcall(function() out:set(lines) end)
		pcall(function()
			win:SetStatus(string.format("%s str   lvl %d   reb %d   %s wins   %s",
				short(STATE.strength), STATE.level, STATE.rebirths, short(STATE.wins), STATE.phase))
		end)
		task.wait(0.5)
	end
end)

win:Refresh()

--------------------------------------------------------------------------------

_G.__MUSCLE_DBG = {
	CONFIG = CONFIG, STATE = STATE,
	data = data, levelOf = levelOf, hop = hop,
	bestTrainZone = bestTrainZone, standInZone = standInZone,
	claimWins = claimWins, buyBestBody = buyBestBody,
	doRebirth = doRebirth, rebirthReady = rebirthReady,
	Click = ClickController,
}

print("[muscleevo] gen " .. GEN .. " ready - RightShift for the panel")
