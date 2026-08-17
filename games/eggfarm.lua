--!nocheck
-- Grow a Chicken Fighter - auto egg collector + auto hatcher with a small UI.
--
-- Eggs are Parts inside Workspace.NestEggs carrying the attributes
--   owner  = UserId of the player the egg belongs to
--   eggId  = id used by the HatchEgg RemoteFunction
--   tier   = "feed" | "barn" | "storm" | "crown" | ...
-- Pickup happens through the part's TouchInterest, so we fire that instead of
-- walking. Hatching goes through ReplicatedStorage.Remotes.HatchEgg(eggId),
-- which answers {ok = boolean, error = string}. The server rate limits it, so
-- hatches are queued and spaced out.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

local plr = Players.LocalPlayer

local CONFIG = {
	collect = true,          -- fire TouchInterest on our own eggs
	hatch = false,           -- invoke HatchEgg for collected eggs
	onlyMine = true,         -- ignore eggs owned by other players
	scanInterval = 0.5,      -- seconds between sweeps of the NestEggs folder
	hatchInterval = 1.2,     -- seconds between HatchEgg invokes
	rateLimitBackoff = 4.0,  -- extra wait after the server says rateLimited
	maxHatchTries = 3,
	maxRange = math.huge,    -- studs; set to e.g. 250 to stay local
}

local STATE = {
	collected = 0,
	hatched = 0,
	failed = 0,
	queue = {},              -- eggIds waiting to be hatched
	tries = {},              -- eggId -> attempts
	seen = {},               -- eggId -> true, avoids double collecting
	lastError = "-",
	nextHatch = 0,
}

-- Single-instance guard: re-executing the script replaces the old loops/UI.
_G.__EGGFARM = (_G.__EGGFARM or 0) + 1
local generation = _G.__EGGFARM
if _G.__EGGFARM_GUI then
	pcall(function() _G.__EGGFARM_GUI:Destroy() end)
end

local touchFire = firetouchinterest
local hatchRemote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("HatchEgg")
local nestFolder = workspace:WaitForChild("NestEggs")

-- Collecting -----------------------------------------------------------------

local function rootPart()
	local char = plr.Character
	return char and char:FindFirstChild("HumanoidRootPart")
end

local function eggIsOurs(part)
	return part:GetAttribute("owner") == plr.UserId
end

local function collectEgg(part)
	local hrp = rootPart()
	if not hrp or not part:IsA("BasePart") then return false end

	if CONFIG.maxRange ~= math.huge then
		if (part.Position - hrp.Position).Magnitude > CONFIG.maxRange then return false end
	end

	if touchFire then
		touchFire(hrp, part, 0)
		touchFire(hrp, part, 1)
		return true
	end

	-- No firetouchinterest: briefly hop onto the egg and come back.
	local origin = hrp.CFrame
	hrp.CFrame = CFrame.new(part.Position)
	task.wait(0.12)
	hrp.CFrame = origin
	return true
end

local function handleEgg(part)
	if not part:IsA("BasePart") then return end
	if CONFIG.onlyMine and not eggIsOurs(part) then return end

	local eggId = part:GetAttribute("eggId")
	if not eggId or STATE.seen[eggId] then return end

	if collectEgg(part) then
		STATE.seen[eggId] = true
		STATE.collected += 1
		table.insert(STATE.queue, eggId)
	end
end

-- Hatching -------------------------------------------------------------------

local function hatchOne(eggId)
	local ok, res = pcall(function()
		return hatchRemote:InvokeServer(eggId)
	end)

	if not ok then
		STATE.lastError = "invoke failed"
		return false, true
	end

	if type(res) == "table" and res.ok then
		STATE.hatched += 1
		STATE.lastError = "-"
		return true, false
	end

	local err = type(res) == "table" and tostring(res.error) or "no response"
	STATE.lastError = err

	if err == "rateLimited" then
		return false, true  -- retry this one later
	end

	STATE.failed += 1
	return false, false     -- permanent failure, drop it
end

local function pumpHatchQueue()
	if not CONFIG.hatch or #STATE.queue == 0 then return end
	if os.clock() < STATE.nextHatch then return end

	local eggId = table.remove(STATE.queue, 1)
	local done, retry = hatchOne(eggId)
	STATE.nextHatch = os.clock() + CONFIG.hatchInterval

	if not done and retry then
		STATE.tries[eggId] = (STATE.tries[eggId] or 0) + 1
		if STATE.tries[eggId] < CONFIG.maxHatchTries then
			table.insert(STATE.queue, eggId)
			STATE.nextHatch = os.clock() + CONFIG.rateLimitBackoff
		else
			STATE.failed += 1
		end
	end
end

-- UI -------------------------------------------------------------------------

local COLORS = {
	bg = Color3.fromRGB(18, 18, 22),
	panel = Color3.fromRGB(28, 28, 34),
	on = Color3.fromRGB(80, 200, 120),
	off = Color3.fromRGB(70, 70, 80),
	text = Color3.fromRGB(235, 235, 240),
	dim = Color3.fromRGB(150, 150, 160),
	accent = Color3.fromRGB(250, 200, 80),
}

local function corner(parent, radius)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius or 6)
	c.Parent = parent
	return c
end

local gui = Instance.new("ScreenGui")
gui.Name = "EggFarm"
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
pcall(function()
	gui.Parent = (gethui and gethui()) or game:GetService("CoreGui")
end)
if not gui.Parent then gui.Parent = plr:WaitForChild("PlayerGui") end
_G.__EGGFARM_GUI = gui

local frame = Instance.new("Frame")
frame.Size = UDim2.fromOffset(230, 196)
frame.Position = UDim2.new(0, 20, 0.5, -98)
frame.BackgroundColor3 = COLORS.bg
frame.BorderSizePixel = 0
frame.Active = true
frame.Draggable = true
frame.Parent = gui
corner(frame, 10)

local stroke = Instance.new("UIStroke")
stroke.Color = Color3.fromRGB(60, 60, 70)
stroke.Thickness = 1
stroke.Parent = frame

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, 0, 0, 32)
title.BackgroundTransparency = 1
title.Text = "  EGG FARM"
title.TextXAlignment = Enum.TextXAlignment.Left
title.TextColor3 = COLORS.accent
title.Font = Enum.Font.GothamBold
title.TextSize = 14
title.Parent = frame

local hint = Instance.new("TextLabel")
hint.Size = UDim2.new(0, 60, 0, 32)
hint.Position = UDim2.new(1, -66, 0, 0)
hint.BackgroundTransparency = 1
hint.Text = "RShift"
hint.TextColor3 = COLORS.dim
hint.Font = Enum.Font.Gotham
hint.TextSize = 11
hint.Parent = frame

local function makeToggle(text, y, key)
	local button = Instance.new("TextButton")
	button.Size = UDim2.new(1, -20, 0, 34)
	button.Position = UDim2.new(0, 10, 0, y)
	button.BackgroundColor3 = COLORS.panel
	button.BorderSizePixel = 0
	button.Text = ""
	button.AutoButtonColor = false
	button.Parent = frame
	corner(button, 6)

	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, -60, 1, 0)
	label.Position = UDim2.new(0, 12, 0, 0)
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextColor3 = COLORS.text
	label.Font = Enum.Font.Gotham
	label.TextSize = 13
	label.Parent = button

	local pill = Instance.new("Frame")
	pill.Size = UDim2.fromOffset(38, 20)
	pill.Position = UDim2.new(1, -48, 0.5, -10)
	pill.BackgroundColor3 = CONFIG[key] and COLORS.on or COLORS.off
	pill.BorderSizePixel = 0
	pill.Parent = button
	corner(pill, 10)

	local knob = Instance.new("Frame")
	knob.Size = UDim2.fromOffset(16, 16)
	knob.Position = CONFIG[key] and UDim2.new(1, -18, 0, 2) or UDim2.new(0, 2, 0, 2)
	knob.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	knob.BorderSizePixel = 0
	knob.Parent = pill
	corner(knob, 8)

	button.MouseButton1Click:Connect(function()
		CONFIG[key] = not CONFIG[key]
		local info = TweenInfo.new(0.15, Enum.EasingStyle.Quad)
		TweenService:Create(pill, info, {
			BackgroundColor3 = CONFIG[key] and COLORS.on or COLORS.off,
		}):Play()
		TweenService:Create(knob, info, {
			Position = CONFIG[key] and UDim2.new(1, -18, 0, 2) or UDim2.new(0, 2, 0, 2),
		}):Play()
	end)

	return button
end

makeToggle("Auto Collect", 36, "collect")
makeToggle("Auto Hatch", 74, "hatch")
makeToggle("Only My Eggs", 112, "onlyMine")

local status = Instance.new("TextLabel")
status.Size = UDim2.new(1, -20, 0, 40)
status.Position = UDim2.new(0, 10, 0, 150)
status.BackgroundTransparency = 1
status.TextXAlignment = Enum.TextXAlignment.Left
status.TextYAlignment = Enum.TextYAlignment.Top
status.TextColor3 = COLORS.dim
status.Font = Enum.Font.Code
status.TextSize = 11
status.Text = ""
status.Parent = frame

UserInputService.InputBegan:Connect(function(input, typing)
	if typing then return end
	if input.KeyCode == Enum.KeyCode.RightShift then
		frame.Visible = not frame.Visible
	end
end)

-- Loops ----------------------------------------------------------------------

nestFolder.ChildAdded:Connect(function(part)
	if _G.__EGGFARM ~= generation then return end
	if not CONFIG.collect then return end
	task.wait(0.1)  -- let attributes replicate
	pcall(handleEgg, part)
end)

task.spawn(function()
	while _G.__EGGFARM == generation do
		if CONFIG.collect then
			for _, part in ipairs(nestFolder:GetChildren()) do
				pcall(handleEgg, part)
			end
		end
		task.wait(CONFIG.scanInterval)
	end
end)

task.spawn(function()
	while _G.__EGGFARM == generation do
		pcall(pumpHatchQueue)
		task.wait(0.2)
	end
end)

task.spawn(function()
	while _G.__EGGFARM == generation do
		status.Text = string.format(
			"collected %d   hatched %d\nqueue %d  fail %d  %s",
			STATE.collected, STATE.hatched, #STATE.queue, STATE.failed, STATE.lastError
		)
		task.wait(0.3)
	end
	gui:Destroy()
end)

print("[eggfarm] running (gen " .. generation .. ") - RightShift toggles the UI")
