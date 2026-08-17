--!nocheck
-- +1 Skill Point Legends  --  place 135668295983945  --  seltonmt
--
-- This game is unusually open: there are no named remotes at all, everything
-- goes through ByteNet (two binary channels), but the entire client source sits
-- unobfuscated in ReplicatedStorage.Source. That means:
--
--   * every client->server action is a typed packet with a .send(), so nothing
--     has to be guessed - see Source.Packets.Interactions
--   * the whole live client state is a Fusion store at Source.Utils.Values
--   * the economy (49 NPCs, 20 weapons, ranks, chests, perks) is readable
--
-- Measured facts this file relies on, none of them assumed:
--   * skill points accrue at 2.0/s passively (the description claims 1)
--   * a stat point costs exactly 1 SP, flat, at every level tested
--   * statUpdateRequest{stat, amount} is validated server side: a huge amount
--     is rejected outright, negative and zero do nothing, and fractional
--     amounts work but cost proportionally (0.95 SP per point measured, i.e.
--     1:1 within noise) - so there is no rounding edge to exploit
--   * addSkillPoints / addItem / addKilledNpc are accepted by ByteNet but
--     ignored by the server; they are server->client packets
--   * auto farm is built into the game but gated at rank 4 = 2,457,600 total SP,
--     and the gate is enforced server side (sending autoFarmStarted does nothing)

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local plr = Players.LocalPlayer

local Interactions = require(ReplicatedStorage.Source.Packets.Interactions)
local Values = require(ReplicatedStorage.Source.Utils.Values)
local Constants = require(ReplicatedStorage.Source.Utils.Constants)
local NpcTable = require(ReplicatedStorage.Source.Utils.NpcTable)
local RankThresholds = require(ReplicatedStorage.Source.Utils.RankThresholds)

local CONFIG = {
	auto = true,             -- one switch, runs everything below in order

	autoSpend = true,        -- put unspent skill points into stats
	spendKeep = 0,           -- always leave this many unspent
	-- Skill points arrive in batches every ~30s rather than trickling, so the
	-- spend pass runs every second: a batch should be in the stats within a
	-- second of landing, not sit unspent for a whole cycle.
	spendEvery = 1,

	autoClaim = true,        -- rank / daily / like / offline rewards
	claimEvery = 60,

	-- Where skill points go, as weights. Damage first is the standing rule, but
	-- health matters here because the zone monsters hit back hard: a Grassland
	-- Mammoth does 25,000 damage against a starting 100 health.
	weights = {
		["Physical Damage"] = 5,
		["Health"] = 3,
		["Regeneration"] = 1,
		["Speed"] = 1,
		["Magic Damage"] = 0,
		["Jump Power"] = 0,
	},
}

local STATE = {
	sp = 0, unspent = 0, rank = 1, zone = "-",
	spent = 0, claims = 0, spPerSec = 0,
	phase = "idle", note = "-",
}

_G.__SPL = (_G.__SPL or 0) + 1
local generation = _G.__SPL
if _G.__SPL_GUI then pcall(function() _G.__SPL_GUI:Destroy() end) end

-- Fusion values keep their contents in a field that is deliberately awkward to
-- name; peeking it directly is far cheaper than subscribing to every value.
local function peek(value)
	if type(value) ~= "table" then return value end
	return rawget(value, "_EXTREMELY_DANGEROUS_usedAsValue")
end

local function shortNumber(n)
	n = tonumber(n) or 0
	for _, unit in ipairs({ { 1e12, "T" }, { 1e9, "B" }, { 1e6, "M" }, { 1e3, "K" } }) do
		if n >= unit[1] then return string.format("%.2f%s", n / unit[1], unit[2]) end
	end
	return tostring(math.floor(n))
end

-- Decision log ---------------------------------------------------------------
--
-- Same reasoning as the Sell Ores script: a counter the script increments itself
-- has been wrong often enough that only a timestamped record of what was done,
-- next to the server value it moved, is worth anything afterwards.
local LOG = {}

local function logLine(category, text)
	table.insert(LOG, string.format("%s [%s] %s", os.date("%H:%M:%S"), category, text))
	if #LOG > 300 then table.remove(LOG, 1) end
end

local function tailLog(count)
	local out = {}
	for i = math.max(1, #LOG - (count or 30) + 1), #LOG do out[#out + 1] = LOG[i] end
	return out
end

-- State ----------------------------------------------------------------------

local function totalSp()
	local stats = plr:FindFirstChild("leaderstats")
	local sp = stats and stats:FindFirstChild("SP")
	return sp and tonumber(sp.Value) or 0
end

local function readStats()
	local out = {}
	for name, value in pairs(Values.stats) do
		out[tostring(name)] = tonumber(peek(value)) or 0
	end
	return out
end

local function refresh()
	STATE.sp = totalSp()
	STATE.unspent = tonumber(peek(Values.skillPoints)) or 0
	STATE.zone = tostring(peek(Values.zone) or plr:GetAttribute("Zone") or "-")
	STATE.rank = tonumber(plr:GetAttribute("Rank")) or 1
end

-- Rank progress, straight off RankThresholds (45 ranks, total SP earned).
local function rankProgress()
	local sp = STATE.sp
	local current, nextAt = 1, nil
	for index, threshold in ipairs(RankThresholds) do
		if sp >= threshold then current = index else nextAt = threshold break end
	end
	return current, nextAt
end

-- Spending -------------------------------------------------------------------
--
-- statUpdateRequest{stat = <name>, amount = <n>} is the whole API. The server
-- rejects an amount it cannot pay for rather than clamping it, so the batch is
-- sized against the balance first.
local function spendPoints()
	refresh()
	local budget = STATE.unspent - CONFIG.spendKeep
	if budget < 1 then return end

	local total = 0
	for _, weight in pairs(CONFIG.weights) do total = total + math.max(weight, 0) end
	if total <= 0 then return end

	local stats = readStats()
	-- Order matters when the budget is small: without it the loop hands the
	-- rounding remainder to whichever key pairs() happens to yield first, which
	-- is not the one carrying the most weight.
	local order = {}
	for name, weight in pairs(CONFIG.weights) do
		if weight > 0 and stats[name] ~= nil then table.insert(order, name) end
	end
	table.sort(order, function(a, b) return CONFIG.weights[a] > CONFIG.weights[b] end)

	for _, name in ipairs(order) do
		local weight = CONFIG.weights[name]
		do
			local amount = math.floor(budget * (weight / total))
			-- a small batch would otherwise round to zero everywhere and never
			-- get spent at all
			if amount < 1 and budget >= 1 and name == order[1] then amount = math.floor(budget) end
			if amount >= 1 then
				local before = stats[name]
				local ok = pcall(function()
					Interactions.statUpdateRequest.send({ stat = name, amount = amount })
				end)
				if ok then
					task.wait(0.15)
					local after = tonumber(peek(Values.stats[name])) or before
					if after > before then
						STATE.spent = STATE.spent + (after - before)
						STATE.note = string.format("%s +%d", name, after - before)
						logLine("SPEND", string.format("%s %s -> %s (+%s)",
							name, shortNumber(before), shortNumber(after), shortNumber(after - before)))
					end
				end
			end
		end
	end
	refresh()
end

-- Rewards --------------------------------------------------------------------
--
-- All of these are fire-and-forget packets; the server silently ignores a claim
-- that is not due, so there is nothing to check first and nothing to break.
local CLAIMS = {
	{ name = "onRankRewardClaim", label = "rank" },
	{ name = "claimDailyReward", label = "daily" },
	{ name = "claimLikeReward", label = "like" },
	{ name = "onOfflineRewardClaim", label = "offline" },
}

local function claimRewards()
	local before = totalSp()
	for _, claim in ipairs(CLAIMS) do
		local packet = Interactions[claim.name]
		if packet then pcall(function() packet.send() end) end
		task.wait(0.25)
	end
	local gained = totalSp() - before
	if gained > 0 then
		STATE.claims = STATE.claims + 1
		STATE.note = "claimed " .. shortNumber(gained)
		logLine("CLAIM", string.format("rewards paid %s, total %s", shortNumber(gained), shortNumber(totalSp())))
	end
end

-- Income measurement ---------------------------------------------------------

local INCOME = { last = 0, at = 0 }

local function sampleIncome()
	local now = os.clock()
	local sp = totalSp()
	if INCOME.at > 0 and now > INCOME.at then
		local span = now - INCOME.at
		if span >= 5 then
			STATE.spPerSec = (sp - INCOME.last) / span
			INCOME.last, INCOME.at = sp, now
		end
	else
		INCOME.last, INCOME.at = sp, now
	end
end

-- Cycle ----------------------------------------------------------------------

local lastSpend, lastClaim = 0, 0

local function cycle()
	refresh()
	sampleIncome()

	if (CONFIG.auto or CONFIG.autoSpend) and os.clock() - lastSpend >= CONFIG.spendEvery then
		lastSpend = os.clock()
		pcall(spendPoints)
		STATE.phase = "spending"
	end

	if (CONFIG.auto or CONFIG.autoClaim) and os.clock() - lastClaim >= CONFIG.claimEvery then
		lastClaim = os.clock()
		pcall(claimRewards)
	end
end

-- What the script believes is holding progress back, from measured numbers.
local function bottleneck()
	local out = {}
	local rank, nextAt = rankProgress()

	if rank < Constants.AUTO_FARM_UNLOCKS_AT_RANK then
		local need = (RankThresholds[Constants.AUTO_FARM_UNLOCKS_AT_RANK] or 0) - STATE.sp
		local seconds = STATE.spPerSec > 0 and (need / STATE.spPerSec) or -1
		out[#out + 1] = string.format("auto farm locked until rank %d (%s SP short%s)",
			Constants.AUTO_FARM_UNLOCKS_AT_RANK, shortNumber(need),
			seconds > 0 and (", " .. shortNumber(seconds / 60) .. " min at this rate") or "")
	end

	if nextAt then
		out[#out + 1] = string.format("rank %d -> %d needs %s more SP",
			rank, rank + 1, shortNumber(nextAt - STATE.sp))
	end

	-- what the current zone can actually be farmed for
	local zone = STATE.zone
	local best, bestName
	for name, data in pairs(NpcTable) do
		if type(data) == "table" and tostring(data.zone) == zone and not data.boss then
			local sp = tonumber(data.sp) or 0
			if not best or sp > best then best, bestName = sp, name end
		end
	end
	if bestName then
		out[#out + 1] = string.format("best normal mob in %s: %s at %s SP", zone, bestName, shortNumber(best))
	end

	if STATE.unspent > 100 then
		out[#out + 1] = string.format("%s skill points sitting unspent", shortNumber(STATE.unspent))
	end

	if #out == 0 then out[1] = "nothing blocking" end
	return out
end

-- UI -------------------------------------------------------------------------

local COLORS = {
	bg = Color3.fromRGB(15, 16, 20),
	header = Color3.fromRGB(22, 23, 29),
	panel = Color3.fromRGB(30, 32, 40),
	panelHover = Color3.fromRGB(38, 40, 50),
	on = Color3.fromRGB(72, 205, 130),
	off = Color3.fromRGB(58, 60, 70),
	text = Color3.fromRGB(232, 234, 240),
	dim = Color3.fromRGB(138, 142, 155),
	accent = Color3.fromRGB(120, 200, 255),
	warn = Color3.fromRGB(250, 176, 96),
	line = Color3.fromRGB(44, 46, 56),
}

local function corner(parent, radius)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius or 6)
	c.Parent = parent
end

local gui = Instance.new("ScreenGui")
gui.Name = "SkillPointLegends"
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
pcall(function() gui.Parent = (gethui and gethui()) or game:GetService("CoreGui") end)
if not gui.Parent then gui.Parent = plr:WaitForChild("PlayerGui") end
_G.__SPL_GUI = gui

local frame = Instance.new("Frame")
frame.Size = UDim2.fromOffset(600, 420)
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

local title = Instance.new("TextLabel")
title.Size = UDim2.new(0, 260, 0, 20)
title.Position = UDim2.new(0, 14, 0, 8)
title.BackgroundTransparency = 1
title.Text = "SKILL POINT LEGENDS"
title.TextXAlignment = Enum.TextXAlignment.Left
title.TextColor3 = COLORS.text
title.Font = Enum.Font.GothamBold
title.TextSize = 13
title.Parent = header

local credit = Instance.new("TextLabel")
credit.Size = UDim2.fromOffset(100, 20)
credit.Position = UDim2.new(0, 176, 0, 8)
credit.BackgroundTransparency = 1
credit.Text = "by seltonmt"
credit.TextXAlignment = Enum.TextXAlignment.Left
credit.TextColor3 = COLORS.accent
credit.Font = Enum.Font.GothamMedium
credit.TextSize = 11
credit.Parent = header

local headline = Instance.new("TextLabel")
headline.Size = UDim2.new(1, -24, 0, 16)
headline.Position = UDim2.new(0, 14, 0, 28)
headline.BackgroundTransparency = 1
headline.Text = "idle"
headline.TextXAlignment = Enum.TextXAlignment.Left
headline.TextColor3 = COLORS.dim
headline.Font = Enum.Font.Gotham
headline.TextSize = 11
headline.Parent = header

local tabBar = Instance.new("Frame")
tabBar.Size = UDim2.new(1, -16, 0, 24)
tabBar.Position = UDim2.new(0, 8, 0, 56)
tabBar.BackgroundTransparency = 1
tabBar.Parent = frame

local tabLayout = Instance.new("UIListLayout")
tabLayout.FillDirection = Enum.FillDirection.Horizontal
tabLayout.Padding = UDim.new(0, 6)
tabLayout.Parent = tabBar

local pages, tabButtons = {}, {}
local activePage = "CONTROLS"

local function makePage(name)
	local page = Instance.new("ScrollingFrame")
	page.Name = name
	page.Size = UDim2.new(1, -16, 1, -96)
	page.Position = UDim2.new(0, 8, 0, 84)
	page.BackgroundTransparency = 1
	page.BorderSizePixel = 0
	page.ScrollBarThickness = 3
	page.ScrollBarImageColor3 = COLORS.line
	page.AutomaticCanvasSize = Enum.AutomaticSize.Y
	page.CanvasSize = UDim2.new(0, 0, 0, 0)
	page.Visible = false
	page.Parent = frame
	pages[name] = page

	local button = Instance.new("TextButton")
	button.Size = UDim2.fromOffset(96, 24)
	button.BackgroundColor3 = COLORS.panel
	button.BorderSizePixel = 0
	button.Text = name
	button.TextColor3 = COLORS.dim
	button.Font = Enum.Font.GothamMedium
	button.TextSize = 11
	button.AutoButtonColor = false
	button.Parent = tabBar
	corner(button, 6)
	tabButtons[name] = button

	button.MouseButton1Click:Connect(function()
		activePage = name
		for pageName, other in pairs(pages) do
			other.Visible = pageName == name
			tabButtons[pageName].TextColor3 = pageName == name and COLORS.text or COLORS.dim
			tabButtons[pageName].BackgroundColor3 = pageName == name and COLORS.panelHover or COLORS.panel
		end
	end)
	return page
end

local body = makePage("CONTROLS")
local statusPage = makePage("STATUS")
local logPage = makePage("LOG")
body.Visible = true
tabButtons.CONTROLS.TextColor3 = COLORS.text
tabButtons.CONTROLS.BackgroundColor3 = COLORS.panelHover

local grid = Instance.new("UIGridLayout")
grid.CellSize = UDim2.new(0.5, -6, 0, 30)
grid.CellPadding = UDim2.fromOffset(8, 5)
grid.SortOrder = Enum.SortOrder.LayoutOrder
grid.Parent = body

for _, page in ipairs({ statusPage, logPage }) do
	local list = Instance.new("UIListLayout")
	list.Padding = UDim.new(0, 2)
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Parent = page
end

local function makeMono(parent, order)
	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, -8, 0, 16)
	label.BackgroundTransparency = 1
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextColor3 = COLORS.dim
	label.Font = Enum.Font.Code
	label.TextSize = 11
	label.Text = ""
	label.LayoutOrder = order
	label.Parent = parent
	return label
end

local statusLines, logLines = {}, {}
for i = 1, 20 do statusLines[i] = makeMono(statusPage, i) end
for i = 1, 20 do logLines[i] = makeMono(logPage, i) end

local order = 0
local function makeToggle(text, key, tone)
	order = order + 1
	local button = Instance.new("TextButton")
	button.BackgroundColor3 = COLORS.panel
	button.BorderSizePixel = 0
	button.Text = ""
	button.AutoButtonColor = false
	button.LayoutOrder = order
	button.Parent = body
	corner(button, 7)

	local mark = Instance.new("Frame")
	mark.Size = UDim2.fromOffset(3, 18)
	mark.Position = UDim2.new(0, 8, 0.5, -9)
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

	button.MouseButton1Click:Connect(function()
		CONFIG[key] = not CONFIG[key]
		local info = TweenInfo.new(0.15, Enum.EasingStyle.Quad)
		TweenService:Create(pill, info, { BackgroundColor3 = CONFIG[key] and COLORS.on or COLORS.off }):Play()
		TweenService:Create(knob, info, {
			Position = CONFIG[key] and UDim2.new(1, -16, 0, 2) or UDim2.new(0, 2, 0, 2),
		}):Play()
		mark.BackgroundColor3 = CONFIG[key] and (tone or COLORS.on) or COLORS.off
	end)
end

makeToggle("AUTO (everything)", "auto", COLORS.warn)
makeToggle("Spend skill points", "autoSpend")
makeToggle("Claim rewards", "autoClaim")

local footer = Instance.new("TextLabel")
footer.Size = UDim2.new(1, -16, 0, 14)
footer.Position = UDim2.new(0, 8, 1, -18)
footer.BackgroundTransparency = 1
footer.TextXAlignment = Enum.TextXAlignment.Left
footer.TextColor3 = COLORS.dim
footer.Font = Enum.Font.Code
footer.TextSize = 11
footer.Text = ""
footer.Parent = frame

UserInputService.InputBegan:Connect(function(input, typing)
	if typing then return end
	if input.KeyCode == Enum.KeyCode.RightShift then frame.Visible = not frame.Visible end
end)

-- Loops ----------------------------------------------------------------------

task.spawn(function()
	while _G.__SPL == generation do
		pcall(cycle)
		task.wait(1)
	end
end)

task.spawn(function()
	while _G.__SPL == generation do
		local rank, nextAt = rankProgress()
		headline.Text = string.format("%s SP   %s unspent   %.1f SP/s   rank %d   %s",
			shortNumber(STATE.sp), shortNumber(STATE.unspent), STATE.spPerSec, rank, STATE.zone)
		footer.Text = string.format("spent %s   claims %d   %s   %s",
			shortNumber(STATE.spent), STATE.claims, STATE.phase, STATE.note)

		if activePage == "STATUS" then
			local lines = { "STATS" }
			local stats = readStats()
			for _, name in ipairs({ "Physical Damage", "Magic Damage", "Health", "Regeneration", "Speed", "Jump Power" }) do
				if stats[name] then
					lines[#lines + 1] = string.format("  %-18s %s", name, shortNumber(stats[name]))
				end
			end
			lines[#lines + 1] = ""
			lines[#lines + 1] = "PROGRESS"
			lines[#lines + 1] = string.format("  total %s   unspent %s   %.1f SP/s",
				shortNumber(STATE.sp), shortNumber(STATE.unspent), STATE.spPerSec)
			if nextAt then
				lines[#lines + 1] = string.format("  rank %d, next at %s", rank, shortNumber(nextAt))
			end
			lines[#lines + 1] = ""
			lines[#lines + 1] = "WHAT IS HOLDING US BACK"
			for _, line in ipairs(bottleneck()) do lines[#lines + 1] = "  " .. line end

			for i, label in ipairs(statusLines) do
				label.Text = lines[i] or ""
				label.TextColor3 = (lines[i] and lines[i]:match("^%u[%u ]+$")) and COLORS.accent or COLORS.dim
			end
		elseif activePage == "LOG" then
			local recent = tailLog(#logLines)
			for i, label in ipairs(logLines) do
				label.Text = recent[#recent - i + 1] or ""
			end
		end

		task.wait(0.5)
	end
	gui:Destroy()
end)

_G.__SPL_DBG = {
	CONFIG = CONFIG, STATE = STATE, LOG = LOG, tail = tailLog,
	peek = peek, refresh = refresh, readStats = readStats,
	spendPoints = spendPoints, claimRewards = claimRewards,
	rankProgress = rankProgress, bottleneck = bottleneck, cycle = cycle,
	Interactions = Interactions, Values = Values,
}

refresh()
logLine("BOOT", string.format("gen %d, %s SP, rank %d, zone %s",
	generation, shortNumber(STATE.sp), STATE.rank, STATE.zone))
