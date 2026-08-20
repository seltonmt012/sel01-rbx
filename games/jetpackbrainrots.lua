--!nocheck
-- [+1 Jetpack for Brainrots] place 80234914611737 - full farm loop.
--
-- Everything below was measured against a server value, not assumed:
--
--   * Free CFrame teleporting works. A 400 stud warp did not snap back, the game
--     teleports players itself (Game.RF.TeleportToBase) and its zones are radius
--     based (ZoneConfigs.RANGE 100), so no firetouchinterest gymnastics are
--     needed anywhere. That is the reason this game was picked over the last one.
--   * Picking a brainrot up: warp onto it, hold the root part there for ~1.2s,
--     then fireproximityprompt. Verified: the model became a child of the
--     character and the player attribute isCarryingRewards flipped to true.
--   * Placing: warp to one of the ten BrainrotSlots on your own base and fire its
--     PlacePrompt. **The prompt reports Enabled = false and firing it works
--     anyway** - that flag is set by a client controller and is not the gate.
--     Verified: genPerSecond 0 -> 12,076/s.
--   * Money is claimed with a plain remote, no position needed:
--     Game.RF.ClaimEarnings("1") where the argument is the slot key as a STRING.
--     Verified: cash 0 -> 1,412,892.
--   * leaderstats.Cash and leaderstats["Gen/s"] are **StringValues for display**
--     ("$12.08K/s"). Never parse them. The real state is a Rodux store found in
--     getgc, and every currency in it is a BigNum table {mantissa, exponent}
--     decoded with the game's own PlaywooEngine.Utils.BigNum.
--   * Rarity ranking comes from Info.BrainrotsInfo.byKey[<model name>].rarity
--     and BrainrotConfigs.GetRarityBaseRevenuePerSecond(rarity), which steps x8
--     per rarity (common 8 ... divine 1.07e9). A published script ranked by the
--     *folder* name instead - those folders are grid cells like "-1,0,-8", not
--     rarities, so that ranking was noise.
--   * No client side anti-cheat: sweeps over 16,806 functions found no position
--     check, no snapback, no reporting remote. Only a tutorial funnel. What the
--     server checks is unknown, so every claim here is backed by the store.
--
-- Robux, never touched: Store.RF.Purchase*, the three paid jetpacks, and any
-- upgrade that answers with a product prompt.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local plr = Players.LocalPlayer

local CONFIG = {
	autoFarm = false,        -- fly out, pick the best brainrot up, bring it home
	autoPlace = true,        -- put what we carry into a free base slot
	autoClaim = true,        -- ClaimEarnings on every occupied slot
	claimEvery = 20,         -- seconds between claim passes
	minRarityIndex = 1,      -- skip anything below this rarity (see RARITY_ORDER)
	fillFirst = true,        -- fill empty slots before replacing weaker ones
	autoUpgradeBrainrot = false,  -- level the placed brainrots
	autoUpgradeBase = false, -- buy more slots
	autoBoost = false,       -- boost is the flight range, and the rebirth gate
	autoRebirth = false,     -- resets boost, keeps brainrots, +0.5 multiplier
	autoFreeRewards = true,  -- daily / playtime / group / offline
	pickupSettle = 1.2,      -- seconds pinned on the item before firing the prompt
	replaceWeak = true,      -- a full plot swaps its worst earner for a better one
	upgradesPerPass = 4,     -- slots levelled per pass, best payback first
	paybackCap = 600,        -- seconds; refuse levels slower than this
	swapsPerPass = 6,        -- how many slots one reconciliation may fix
	swapMargin = 1.25,       -- a spare must beat the worst slot by this factor
	sellSpare = true,        -- sell whatever the plot has outgrown
	autoLuckyBlocks = true,  -- open any lucky block the account is holding
}

local STATE = {
	cash = 0, gen = 0, level = 0, rebirths = 0, boost = 0,
	slotsUsed = 0, slotsTotal = 0, carrying = false,
	picked = 0, placed = 0, claims = 0, claimed = 0,
	upgrades = 0, upgradeSpend = 0, rewards = 0, rebirthsDone = 0,
	replaced = 0, skipped = 0, sold = 0, blocksOpened = 0,
	rebirthNeed = 0, worst = 0, best = 0,
	phase = "idle", note = "-", uiOwner = "-", target = "-",
	startCash = 0, startedAt = os.clock(),
}

_G.__JETPACK = (_G.__JETPACK or 0) + 1
local generation = _G.__JETPACK

-- Re-executing does not restart the Lua VM, so the previous panel is still
-- parented to CoreGui. Destroy the stored window and sweep the named ScreenGui,
-- because a run that errored early never stored one.
local PANEL_NAME = "JETPACKBRAINROTS"
if _G.__JETPACK_WIN then
	pcall(function() _G.__JETPACK_WIN:Destroy() end)
	_G.__JETPACK_WIN = nil
end
pcall(function()
	local host = (gethui and gethui()) or game:GetService("CoreGui")
	for _, child in ipairs(host:GetChildren()) do
		if child.Name == PANEL_NAME then child:Destroy() end
	end
end)

-- Game modules ---------------------------------------------------------------

local Source = ReplicatedStorage:WaitForChild("Source", 10)
local BigNum = require(Source.PlaywooEngine.Utils.BigNum)
local BrainrotsInfo = require(Source.Info.BrainrotsInfo)

local BrainrotConfigs
do
	for _, m in ipairs(Source:GetDescendants()) do
		if m:IsA("ModuleScript") and m.Name == "BrainrotConfigs" then
			local ok, cfg = pcall(require, m)
			if ok then BrainrotConfigs = cfg end
			break
		end
	end
end

local RARITY_ORDER = {
	"common", "uncommon", "rare", "epic", "legendary",
	"mythical", "cosmic", "secret", "celestial", "divine",
}
local RARITY_INDEX = {}
for i, name in ipairs(RARITY_ORDER) do RARITY_INDEX[name] = i end

-- Remotes are Knit RFs with plain names; resolving by name once and caching is
-- enough, the path is long and version stamped
-- (Packages._Index["sleitnick_knit@1.7.0"].knit.Services.Game.RF.<Name>).
local remoteCache = {}
local function remote(name)
	if remoteCache[name] and remoteCache[name].Parent then return remoteCache[name] end
	for _, d in ipairs(ReplicatedStorage:GetDescendants()) do
		if d.Name == name and (d:IsA("RemoteFunction") or d:IsA("RemoteEvent")) then
			remoteCache[name] = d
			return d
		end
	end
	return nil
end

-- A yielding InvokeServer parks the bridge's poll loop for good, and it parks
-- this script just as dead. Every invoke runs in its own thread behind a wall
-- clock cap; a remote that never answers costs `timeout` seconds, not the run.
local function invoke(name, timeout, ...)
	local rf = remote(name)
	if not rf or not rf:IsA("RemoteFunction") then return false, "missing" end
	local args = table.pack(...)
	local done, result = false, nil
	task.spawn(function()
		local ok, res = pcall(function() return rf:InvokeServer(table.unpack(args, 1, args.n)) end)
		done, result = true, ok and res or nil
	end)
	local deadline = os.clock() + (timeout or 6)
	while not done and os.clock() < deadline and _G.__JETPACK == generation do
		task.wait(0.1)
	end
	return done, result
end

-- State ----------------------------------------------------------------------

-- The store is the only honest mirror. It sits in getgc and there is exactly one
-- table whose getState() carries data.currencies, so the scan is cheap and
-- unambiguous; it is cached in _G because getgc over ~120k objects is not free.
local function findStore()
	if _G.__JETPACK_STORE then
		local ok, st = pcall(function() return _G.__JETPACK_STORE:getState() end)
		if ok and type(st) == "table" and st.data then return _G.__JETPACK_STORE end
	end
	for _, v in ipairs(getgc(true)) do
		if type(v) == "table" then
			local ok, fn = pcall(function() return v.getState end)
			if ok and type(fn) == "function" then
				local ok2, st = pcall(function() return v:getState() end)
				if ok2 and type(st) == "table" and st.data and st.data.currencies then
					_G.__JETPACK_STORE = v
					return v
				end
			end
		end
	end
	return nil
end

local function data()
	local store = findStore()
	if not store then return nil end
	local ok, st = pcall(function() return store:getState() end)
	if not ok then return nil end
	return st.data
end

local function num(value)
	if type(value) == "table" then
		local ok, n = pcall(BigNum.ToNumber, value)
		return ok and n or 0
	end
	return tonumber(value) or 0
end

local function short(n)
	n = tonumber(n) or 0
	local units = { { 1e15, "Qa" }, { 1e12, "T" }, { 1e9, "B" }, { 1e6, "M" }, { 1e3, "K" } }
	for _, u in ipairs(units) do
		if math.abs(n) >= u[1] then return string.format("%.2f%s", n / u[1], u[2]) end
	end
	return string.format("%.0f", n)
end

local function note(text) STATE.note = text end

-- Forward declaration: the plot inventory helpers need the rarity lookup, and it
-- is defined further down with the rest of the value model. A local is invisible
-- above its definition, and because every action runs inside pcall that would
-- have surfaced as a quiet footer note instead of an error.
local rarityOf

-- The farm loop calls the reconciliation on the way home, and that lives down in
-- the money section with the selling. Same reason as above: a local is invisible
-- above its definition and the pcall around every action would swallow it.
local reconcilePlot

local function character()
	local char = plr.Character
	if not char or not char.Parent then return nil end
	return char, char:FindFirstChild("HumanoidRootPart")
end

-- Position -------------------------------------------------------------------

local function pin(cf, seconds)
	local _, hrp = character()
	if not hrp then return false end
	local target = cf
	local conn = RunService.Heartbeat:Connect(function()
		if hrp.Parent then hrp.CFrame = target end
	end)
	local deadline = os.clock() + (seconds or 1)
	while os.clock() < deadline and _G.__JETPACK == generation do task.wait() end
	conn:Disconnect()
	return true
end

local function withPin(getCFrame, fn)
	local _, hrp = character()
	if not hrp then return false end
	local target = getCFrame()
	local conn = RunService.Heartbeat:Connect(function()
		if hrp.Parent then hrp.CFrame = target end
	end)
	local ok, err = pcall(fn, function(cf) target = cf end)
	conn:Disconnect()
	if not ok then note("move failed: " .. tostring(err)) end
	return ok
end

local busy = false
local function withUI(name, fn)
	if busy then return false end
	busy = true
	STATE.uiOwner = name
	local ok, err = pcall(fn)
	busy = false
	STATE.uiOwner = "-"
	if not ok then note(name .. " failed: " .. tostring(err)) end
	return ok
end

-- Base -----------------------------------------------------------------------

local function myBase()
	local map = workspace:FindFirstChild("Map")
	local bases = map and map:FindFirstChild("PlayerBases")
	if not bases then return nil end
	-- The player attribute is authoritative; the OwnerDisplayPart label was used
	-- to confirm it once (base 4 read "Lumo_Studios") and matches.
	local index = plr:GetAttribute("baseNumber")
	local folder = index and bases:FindFirstChild(tostring(index))
	return folder and folder:FindFirstChild("Base") or nil
end

local function slotFolders()
	local base = myBase()
	local slots = base and base:FindFirstChild("BrainrotSlots")
	if not slots then return {} end
	return slots:GetChildren()
end

local function occupiedSlots()
	local d = data()
	local used, keys = 0, {}
	if d and type(d.baseBrainrotSlots) == "table" then
		for key, uid in pairs(d.baseBrainrotSlots) do
			if uid and uid ~= "" then
				used = used + 1
				keys[#keys + 1] = tostring(key)
			end
		end
	end
	return used, keys
end

local function slotByName(name)
	for _, slot in ipairs(slotFolders()) do
		if slot.Name == tostring(name) then return slot end
	end
	return nil
end

-- The plot, valued slot by slot. A placed brainrot's uid resolves in
-- data.baseInventory (NOT data.inventory - that one only holds what is still
-- loose), and the entry carries the level and a BigNum revenuePerSecond, which
-- is the real number to compare against.
local function placedBrainrots()
	local d = data()
	local out = {}
	if not d or type(d.baseBrainrotSlots) ~= "table" then return out end
	for key, uid in pairs(d.baseBrainrotSlots) do
		if uid and uid ~= "" then
			local item = (d.baseInventory and d.baseInventory[uid])
				or (d.inventory and d.inventory[uid])
			if item then
				out[#out + 1] = {
					slot = tostring(key), uid = uid, key = item.key,
					level = tonumber(item.level) or 1,
					revenue = num(item.revenuePerSecond),
					rarity = rarityOf(item.key),
				}
			end
		end
	end
	return out
end

-- What the plot's worst earner makes. Anything brought home has to beat this or
-- it is not worth a slot.
local function weakestPlaced()
	local placed = placedBrainrots()
	if #placed == 0 then return nil, 0 end
	local worst = placed[1]
	for _, entry in ipairs(placed) do
		if entry.revenue < worst.revenue then worst = entry end
	end
	return worst, worst.revenue
end

-- Loose brainrots waiting in the inventory, best first.
local function inventoryBrainrots()
	local d = data()
	local out = {}
	if not d or type(d.inventory) ~= "table" then return out end
	for uid, item in pairs(d.inventory) do
		if type(item) == "table" and item.type == "brainrot" then
			out[#out + 1] = {
				uid = uid, key = item.key, level = tonumber(item.level) or 1,
				revenue = num(item.revenuePerSecond), rarity = rarityOf(item.key),
			}
		end
	end
	table.sort(out, function(a, b) return a.revenue > b.revenue end)
	return out
end

local function freeSlot()
	local d = data()
	local taken = {}
	if d and type(d.baseBrainrotSlots) == "table" then
		for key, uid in pairs(d.baseBrainrotSlots) do
			if uid and uid ~= "" then taken[tostring(key)] = true end
		end
	end
	for _, slot in ipairs(slotFolders()) do
		if not taken[slot.Name] then return slot end
	end
	return nil
end

-- Value model ----------------------------------------------------------------

-- Rarity is the whole ranking: the base revenue steps x8 per rarity, so a single
-- step up beats any amount of levelling on a weaker one. Models in the world are
-- named after the brainrot key; a few spawn under a bare rarity name instead,
-- and those are read directly.
function rarityOf(modelName)
	local entry = BrainrotsInfo.byKey and BrainrotsInfo.byKey[modelName]
	if entry and entry.rarity then return entry.rarity end
	local lowered = string.lower(modelName or "")
	if RARITY_INDEX[lowered] then return lowered end
	return nil
end

local function rarityValue(rarity)
	if not rarity then return 0 end
	if BrainrotConfigs and BrainrotConfigs.GetRarityBaseRevenuePerSecond then
		local ok, value = pcall(BrainrotConfigs.GetRarityBaseRevenuePerSecond, rarity)
		if ok then return num(value) end
	end
	return (RARITY_INDEX[rarity] or 0) * 8
end

-- Farming --------------------------------------------------------------------

local function carrying()
	return plr:GetAttribute("isCarryingRewards") == true
end

-- Brainrots spawn in two places: the normal field (workspace.Brainrots) and
-- whatever a lucky block drops (workspace.LuckyBlockBrainrots). Both use the
-- same "Pick up" prompt, so both are scanned - otherwise a block's reward would
-- sit on the floor while the farm flies past it.
local function brainrotSources()
	local out = {}
	for _, name in ipairs({ "Brainrots", "LuckyBlockBrainrots" }) do
		local folder = workspace:FindFirstChild(name)
		if folder then out[#out + 1] = folder end
	end
	return out
end

local function bestBrainrot()
	local sources = brainrotSources()
	if #sources == 0 then return nil end
	local folder = { GetDescendants = function()
		local all = {}
		for _, source in ipairs(sources) do
			for _, node in ipairs(source:GetDescendants()) do all[#all + 1] = node end
		end
		return all
	end }
	local best, bestScore, bestName
	for _, d in ipairs(folder:GetDescendants()) do
		if d:IsA("ProximityPrompt") then
			local model = d:FindFirstAncestorWhichIsA("Model")
			if model and model:IsDescendantOf(workspace) then
				local rarity = rarityOf(model.Name)
				local index = rarity and RARITY_INDEX[rarity] or 0
				if index >= CONFIG.minRarityIndex then
					local score = rarityValue(rarity)
					if not bestScore or score > bestScore then
						best, bestScore, bestName = { model = model, prompt = d }, score, rarity
					end
				end
			end
		end
	end
	if best then best.rarity = bestName; best.score = bestScore end
	return best
end

local function pickUp(entry)
	STATE.phase = "picking up " .. entry.model.Name
	local ok, pivot = pcall(function() return entry.model:GetPivot() end)
	if not ok then return false end
	local taken = false
	withPin(function() return pivot + Vector3.new(0, 3, 0) end, function()
		-- The settle matters: the server validates against its own copy of the
		-- position, and a prompt fired straight after a warp does nothing.
		task.wait(CONFIG.pickupSettle)
		pcall(function() fireproximityprompt(entry.prompt, 1) end)
		task.wait(0.8)
		taken = carrying()
	end)
	if taken then
		STATE.picked = STATE.picked + 1
		note(string.format("picked %s (%s, %s/s base)", entry.model.Name,
			tostring(entry.rarity), short(entry.score)))
	end
	return taken
end

-- The step that makes the whole loop work, and the one that is invisible from
-- the code: a picked up brainrot is only credited once the character CROSSES one
-- of the level gates on the way back. Warping from the field straight onto the
-- base keeps `isCarryingRewards` true forever and the slot prompt stays dead -
-- that is exactly what the first version did, and it looked like the place
-- remote was broken.
--
-- The gates are the thin walls in Map.Levels (Common is 274 x 270 x 2 at
-- z -68, one per rarity out to Cosmic at z -2005). Touching one with
-- firetouchinterest is NOT enough; the character has to travel through it. A
-- glide of ~0.7 studs per frame across the plane does it, and the reward lands
-- in data.inventory as a brainrot entry. Verified: carrying true -> false,
-- inventory gained "BurbaloniLoliloli" level 22, and placing it afterwards took
-- income from 12,076/s to 20,385,174/s.
local function crossLine()
	local levels = workspace.Map and workspace.Map:FindFirstChild("Levels")
	if not levels then return false end
	-- The gate closest to the base is the one worth crossing: coming home you
	-- pass it last, and it is the boundary that credits the carry.
	local gate
	for _, part in ipairs(levels:GetChildren()) do
		if part:IsA("BasePart") then
			if not gate or part.Position.Z > gate.Position.Z then gate = part end
		end
	end
	if not gate then return false end

	STATE.phase = "crossing the line"
	local x, y = gate.Position.X, gate.Position.Y - 30
	local start = Vector3.new(x, y, gate.Position.Z - 27)
	local cur = start
	local crossed = false
	withPin(function() return CFrame.new(cur) end, function(move)
		task.wait(1.0)
		for _ = 1, 90 do
			if _G.__JETPACK ~= generation then break end
			cur = cur + Vector3.new(0, 0, 0.7)
			move(CFrame.new(cur))
			if not carrying() then crossed = true break end
			task.wait()
		end
		task.wait(0.8)
		crossed = crossed or not carrying()
	end)
	if crossed then note("crossed the line, brainrot is in the inventory") end
	return crossed
end

local function placeCarried()
	-- Still on our back? Then the line has not been crossed yet and no slot will
	-- accept it.
	if carrying() then crossLine() end
	local slot = freeSlot()
	-- Swapping lives in reconcilePlot now, which walks every slot; this only
	-- seats what is waiting when there is room.
	if false then
		-- Full plot: only worth it if what is waiting actually beats the worst
		-- earner. Both numbers are the server's own revenuePerSecond, so this is
		-- a like-for-like comparison rather than a guess from the rarity name.
		local waiting = inventoryBrainrots()[1]
		local worst, worstValue = weakestPlaced()
		if waiting and worst and waiting.revenue > worstValue then
			local weakSlot = slotByName(worst.slot)
			local prompt = weakSlot and weakSlot:FindFirstChild("PickupPrompt", true)
			if prompt then
				STATE.phase = "clearing slot " .. worst.slot
				local ok, pivot = pcall(function() return weakSlot:GetPivot() end)
				if ok then
					withPin(function() return pivot + Vector3.new(0, 4, 0) end, function()
						task.wait(1.0)
						pcall(function() fireproximityprompt(prompt, 1) end)
						task.wait(1.2)
					end)
				end
				note(string.format("swapping out %s (%s/s) for %s (%s/s)",
					tostring(worst.key), short(worstValue),
					tostring(waiting.key), short(waiting.revenue)))
				STATE.replaced = STATE.replaced + 1
				slot = freeSlot()
			end
		elseif waiting and worst then
			STATE.skipped = STATE.skipped + 1
			note(string.format("keeping the plot: %s (%s/s) does not beat %s (%s/s)",
				tostring(waiting.key), short(waiting.revenue),
				tostring(worst.key), short(worstValue)))
		end
	end
	if not slot then
		note("no free slot - buy base upgrades or clear one")
		return false
	end
	STATE.phase = "placing"
	local before = 0
	local d = data()
	if d and d.statistics then before = num(d.statistics.genPerSecond) end

	local usedBefore = occupiedSlots()
	local placed = false
	local ok, pivot = pcall(function() return slot:GetPivot() end)
	if not ok then return false end
	withPin(function() return pivot + Vector3.new(0, 4, 0) end, function()
		task.wait(1.0)
		local prompt = slot:FindFirstChild("PlacePrompt", true)
		-- The prompt turns Enabled the moment there is an inventory brainrot to
		-- place; firing it while it still reads disabled also works, so it is
		-- fired either way and the slot count decides whether it counted.
		if prompt then
			pcall(function() fireproximityprompt(prompt, 1) end)
			task.wait(1.2)
			pcall(function() fireproximityprompt(prompt) end)
		end
		task.wait(1.5)
		placed = occupiedSlots() > usedBefore
	end)

	if placed then
		local after = 0
		local d2 = data()
		if d2 and d2.statistics then after = num(d2.statistics.genPerSecond) end
		STATE.placed = STATE.placed + 1
		note(string.format("placed into slot %s, income %s/s -> %s/s",
			slot.Name, short(before), short(after)))
	end
	return placed
end

local function farmCycle()
	-- Anything still on our back has to be walked over the line and put down
	-- before another pickup makes sense - the carry slot holds one at a time.
	if carrying() then
		placeCarried()
		return
	end
	-- Something already in the inventory (a crossing that happened without a
	-- placement) also gets seated first.
	local d0 = data()
	if d0 and type(d0.inventory) == "table" then
		for _, item in pairs(d0.inventory) do
			if type(item) == "table" and item.type == "brainrot" then
				if freeSlot() then placeCarried() end
				break
			end
		end
	end
	-- A full plot is not a reason to stop: with replaceWeak on, the point of the
	-- next trip is to find something that beats the worst earner. Only when
	-- swapping is switched off does farming actually pause.
	if not freeSlot() and not CONFIG.replaceWeak then
		STATE.phase = "base full"
		note("every slot is taken - turn on swapping, or buy base upgrades")
		task.wait(3)
		return
	end
	local entry = bestBrainrot()
	if not entry then
		STATE.phase = "nothing in range"
		task.wait(2)
		return
	end
	STATE.target = entry.model.Name .. " (" .. tostring(entry.rarity) .. ")"
	if pickUp(entry) and CONFIG.autoPlace then
		placeCarried()
		-- One trip home, one full pass over the plot: seat what is better, sell
		-- what is not. Doing it here means the walk back is never wasted.
		reconcilePlot()
	end
end

-- Money ----------------------------------------------------------------------

-- ClaimEarnings takes the slot key as a STRING. A number silently does nothing,
-- which is the same trap Sell Ores had with "Floor2" versus 2.
local function claimAll()
	local before = 0
	local d = data()
	if d then before = num(d.currencies.cash) end
	local _, keys = occupiedSlots()
	for _, key in ipairs(keys) do
		if _G.__JETPACK ~= generation then break end
		invoke("ClaimEarnings", 5, tostring(key))
		task.wait(0.15)
	end
	task.wait(0.6)
	local after = before
	local d2 = data()
	if d2 then after = num(d2.currencies.cash) end
	local gained = after - before
	if gained > 0 then
		STATE.claims = STATE.claims + 1
		STATE.claimed = STATE.claimed + gained
		note("claimed " .. short(gained))
	end
	return gained
end

-- The swap leaves the brainrot it pulled out sitting in the inventory, and the
-- place prompt happily puts it straight back in the freed slot. That churn is
-- what made the plot's worst slot oscillate between 0.066M/s and 0.088M/s while
-- the inventory grew from 2 to 5 entries. Selling the leftovers ends it.
--
-- There is no sell remote at all - the whole thing is the SellStand in the
-- world: "Sell Inventory" (everything loose) and a disabled "Sell Brainrot" for
-- the carried one. Selling the inventory is safe *by construction* because
-- placed brainrots live in baseInventory, not inventory - but it is still only
-- fired once nothing waiting beats the worst slot, so a good pickup is never
-- sold by accident.
-- Which spares are worth keeping, and it is not just the single best one.
--
-- The plot has many slots, so if three spares each beat three different weak
-- slots, all three belong on the plot and none of them may be sold. Locking only
-- the top entry - which is what the first version did - sold the second and
-- third best along with the junk. Compare the sorted spares against the sorted
-- plot, position by position.
local function keepers()
	local waiting = inventoryBrainrots()          -- already best first
	local placed = placedBrainrots()
	table.sort(placed, function(a, b) return a.revenue < b.revenue end)  -- worst first
	local keep = {}
	for i, spare in ipairs(waiting) do
		local rival = placed[i]
		if rival and spare.revenue > rival.revenue * CONFIG.swapMargin then
			keep[#keep + 1] = spare
		end
	end
	return keep, waiting
end

-- Lock everything worth keeping so the sell pass cannot take it, and hand back
-- the list so the caller can unlock afterwards.
local function lockKeepers()
	local keep = keepers()
	for _, entry in ipairs(keep) do
		invoke("ToggleItemLock", 4, entry.uid)
		task.wait(0.15)
	end
	return keep
end

local function unlockAll(list)
	for _, entry in ipairs(list or {}) do
		invoke("ToggleItemLock", 4, entry.uid)
		task.wait(0.1)
	end
end

-- `force` is used from inside a swap, where the keepers are already locked and
-- everything else in the inventory is by definition the junk being cleared out.
local function sellJunkInventory(force)
	local waiting = inventoryBrainrots()
	if #waiting == 0 then return 0 end
	local locked
	if not force then
		-- Protect every spare that still beats a slot before anything is sold.
		locked = lockKeepers()
		waiting = inventoryBrainrots()
		if #locked >= #waiting then
			unlockAll(locked)
			return 0
		end
	end

	local stand = workspace.Map and workspace.Map:FindFirstChild("Stands")
	stand = stand and stand:FindFirstChild("SellStand")
	local prompt = stand and stand:FindFirstChild("ProximityPromptSellInventory", true)
	if not prompt then return 0 end

	local before = num(data().currencies.cash)
	STATE.phase = "selling " .. #waiting .. " spare"
	local ok, pivot = pcall(function() return stand:GetPivot() end)
	if not ok then return 0 end
	withPin(function() return pivot + Vector3.new(0, 4, 0) end, function()
		task.wait(1.0)
		pcall(function() fireproximityprompt(prompt, 1) end)
		task.wait(1.5)
	end)
	local gained = num(data().currencies.cash) - before
	local left = #inventoryBrainrots()
	if gained > 0 then
		STATE.sold = STATE.sold + math.max(#waiting - left, 0)
		note(string.format("sold %d spare for %s, kept %d",
			math.max(#waiting - left, 0), short(gained), left))
	end
	if locked then unlockAll(locked) end
	return gained
end

-- The reconciliation pass, and the part that had to be rewritten: walk the WHOLE
-- plot, price every slot, price everything waiting in the inventory, and keep
-- swapping while the best spare beats the worst slot. The first version did one
-- swap per farm trip and then let the place prompt put the brainrot it had just
-- pulled straight back, so the same slot kept flipping between two values while
-- the inventory grew.
--
-- A swap only happens with a real margin, otherwise two near-equal brainrots
-- trade places forever, and each round is confirmed against the plot's own worst
-- value before the next one starts.
function reconcilePlot()
	if not CONFIG.replaceWeak then return 0 end
	local swaps = 0
	for _ = 1, CONFIG.swapsPerPass do
		if _G.__JETPACK ~= generation then break end
		local waiting = inventoryBrainrots()
		if #waiting == 0 then break end
		local worst, worstValue = weakestPlaced()

		-- A free slot needs no swap at all, just a placement.
		if freeSlot() then
			if not placeCarried() then break end
			swaps = swaps + 1
		elseif worst and waiting[1].revenue > worstValue * CONFIG.swapMargin then
			local weakSlot = slotByName(worst.slot)
			local pickup = weakSlot and weakSlot:FindFirstChild("PickupPrompt", true)
			if not pickup then break end
			STATE.phase = "swapping slot " .. worst.slot

			-- The order here is the whole fix. Pulling a slot and firing Place
			-- straight after just puts the SAME brainrot back - the prompt has no
			-- idea which inventory entry we meant, and the plot's worst slot kept
			-- flipping between two values while nothing improved.
			--
			-- So the inventory is reduced to exactly one candidate first:
			--   1. lock EVERY spare still worth a slot (ToggleItemLock, verified:
			--      locked = true). Locking only the best one sold the second and
			--      third best along with the junk.
			--   2. pull the weak slot   (it lands in the inventory, unlocked)
			--   3. sell the inventory   (the lock is respected - 6 entries went to
			--      1, the locked one survived and the junk paid $46.15B)
			--   4. place; the pulled brainrot is gone, so the prompt seats a keeper
			local locked = lockKeepers()
			task.wait(0.2)

			local ok, pivot = pcall(function() return weakSlot:GetPivot() end)
			if not ok then break end
			withPin(function() return pivot + Vector3.new(0, 4, 0) end, function()
				task.wait(0.9)
				pcall(function() fireproximityprompt(pickup, 1) end)
				task.wait(1.0)
			end)

			if CONFIG.sellSpare then sellJunkInventory(true) end

			withPin(function() return pivot + Vector3.new(0, 4, 0) end, function()
				task.wait(0.8)
				local place = weakSlot:FindFirstChild("PlacePrompt", true)
				if place then
					pcall(function() fireproximityprompt(place, 1) end)
					task.wait(1.2)
				end
			end)
			-- Unlock again so the next sell pass is not blocked by them.
			unlockAll(locked)
			local _, newWorst = weakestPlaced()
			if newWorst > worstValue then
				swaps = swaps + 1
				STATE.replaced = STATE.replaced + 1
				note(string.format("slot %s: %s/s -> %s/s", worst.slot,
					short(worstValue), short(newWorst)))
			else
				-- No improvement: the prompt seated something no better. Stop
				-- rather than trade the same two brainrots back and forth.
				STATE.skipped = STATE.skipped + 1
				note("swap did not improve slot " .. worst.slot .. " - stopping")
				break
			end
		else
			break
		end
	end
	-- Whatever is still loose is by definition worse than every slot, so it is
	-- money rather than clutter.
	if CONFIG.sellSpare then sellJunkInventory() end
	return swaps
end

-- Lucky blocks.
--
-- Thirteen of them exist in Info.LuckyBlocksInfo - ten "regular" (Common through
-- Secret, plus Celestial and Divine) and three "premium" OP_ ones - and none
-- carries a price, so they are not bought: they are held as inventory items and
-- opened at Map.Stands.LuckyBlock (-110, 55, -42), whose prompt reads
-- "Open / Lucky Blocks". The reward lands in workspace.LuckyBlockBrainrots,
-- which the farm scan already covers.
--
-- Honest status: this account owns none right now, so the open itself could not
-- be confirmed end to end. Firing the prompt with an empty inventory did nothing
-- and cost nothing, and `OpenLuckyBlock()` with no argument returned nil. The
-- routine therefore only acts when a block is actually held, and it confirms by
-- the block leaving the inventory rather than by any return value.
local LuckyBlocksInfo
do
	local ok, info = pcall(require, Source.Info.LuckyBlocksInfo)
	if ok then LuckyBlocksInfo = info end
end

local function heldLuckyBlocks()
	local d = data()
	local out = {}
	if not d or type(d.inventory) ~= "table" then return out end
	local byKey = LuckyBlocksInfo and LuckyBlocksInfo.byKey or {}
	for uid, item in pairs(d.inventory) do
		if type(item) == "table" then
			local kind = tostring(item.type or ""):lower()
			if kind:find("lucky") or (item.key and byKey[item.key]) then
				out[#out + 1] = { uid = uid, key = item.key, rarity =
					byKey[item.key] and byKey[item.key].rarity or nil }
			end
		end
	end
	return out
end

local function openLuckyBlocks()
	local blocks = heldLuckyBlocks()
	if #blocks == 0 then return 0 end

	local stand = workspace.Map and workspace.Map:FindFirstChild("Stands")
	stand = stand and stand:FindFirstChild("LuckyBlock")
	local prompt = stand and stand:FindFirstChild("ProximityPromptLuckyBlockStand", true)
	if not stand or not prompt then return 0 end

	STATE.phase = "opening " .. #blocks .. " lucky block(s)"
	local ok, pivot = pcall(function() return stand:GetPivot() end)
	if not ok then return 0 end
	local opened = 0
	withPin(function() return pivot + Vector3.new(0, 4, 0) end, function()
		task.wait(1.0)
		for _, block in ipairs(blocks) do
			if _G.__JETPACK ~= generation then break end
			pcall(function() fireproximityprompt(prompt, 1) end)
			task.wait(1.2)
			-- The remote is tried with the block's own id as well; whichever of
			-- the two the server accepts, the inventory entry disappearing is
			-- the only thing counted.
			invoke("OpenLuckyBlock", 5, block.uid)
			task.wait(0.8)
			local stillHeld = false
			for _, remaining in ipairs(heldLuckyBlocks()) do
				if remaining.uid == block.uid then stillHeld = true end
			end
			if not stillHeld then
				opened = opened + 1
				STATE.blocksOpened = STATE.blocksOpened + 1
				note("opened a " .. tostring(block.key) .. " lucky block")
			end
		end
	end)
	return opened
end

local function claimFreeRewards()
	local before = 0
	local d = data()
	if d then before = num(d.currencies.cash) end
	for _, name in ipairs({
		"ClaimOfflineEarnings", "ClaimDailyReward", "ClaimPlayTimeReward",
		"ClaimGroupReward", "ClaimFreeReward",
	}) do
		if _G.__JETPACK ~= generation then break end
		invoke(name, 5)
		task.wait(0.3)
	end
	task.wait(0.5)
	local after = before
	local d2 = data()
	if d2 then after = num(d2.currencies.cash) end
	if after > before then
		STATE.rewards = STATE.rewards + 1
		note("free rewards +" .. short(after - before))
	end
	return after - before
end

-- Spending -------------------------------------------------------------------

-- Every purchase is confirmed by the cash actually moving. The upgrade cost
-- helpers in the game's configs did not resolve for any argument shape tried, so
-- price is never assumed - the remote is fired and the balance decides whether it
-- counted. A refusal costs nothing and simply stops the pass.
local function buy(name, label, ...)
	local d = data()
	if not d then return false end
	local before = num(d.currencies.cash)
	invoke(name, 6, ...)
	task.wait(0.8)
	local d2 = data()
	local after = d2 and num(d2.currencies.cash) or before
	local spent = before - after
	if spent > 0 then
		STATE.upgrades = STATE.upgrades + 1
		STATE.upgradeSpend = STATE.upgradeSpend + spent
		note(label .. ": -" .. short(spent))
		return true
	end
	return false
end

-- Levelling goes through the slot's own UpgradePrompt, not through the
-- UpgradeBrainrot remote - the remote charged nothing and moved income by
-- rounding error, while three fires of the prompt took a slot from level 24 to
-- 27, income 33.4M/s -> 70.0M/s for 2.60B. That is a 71 second payback, which is
-- better than almost anything else in this game, so it is worth doing early.
-- Every slot carries its own price tag: TextLabelCost ("$66.97B") next to
-- TextLabelLevel ("Level 36 > 37") and TextLabelRevenue. Those are the green
-- buttons floating over the plot, and they are what the upgrade actually costs.
-- The strings are parsed with the game's own BigNum.fromString - a hand written
-- suffix table is how another game in this repo read a $1.56Q unlock as $1.56.
local function labelNumber(label)
	if not label or not label:IsA("TextLabel") then return nil end
	local cleaned = label.Text:gsub("<[^>]->", ""):gsub("[%$,%s]", "")
	if cleaned == "" then return nil end
	local ok, value = pcall(BigNum.fromString, cleaned)
	if ok and type(value) == "table" then return num(value) end
	return tonumber(cleaned)
end

-- One entry per placed brainrot: what levelling it costs and what it is worth.
-- A level multiplies the brainrot's revenue by about 1.28 (measured: level 24 to
-- 27 took 33.4M/s to 70.0M/s), so the gain is proportional to what the slot
-- already earns and the ranking is a real payback, not a price sort - the
-- cheapest slot is by definition the weakest one.
local LEVEL_GAIN = 0.28

local function upgradeCandidates()
	local out = {}
	for _, entry in ipairs(placedBrainrots()) do
		local slot = slotByName(entry.slot)
		local prompt = slot and slot:FindFirstChild("UpgradePrompt", true)
		local cost = slot and labelNumber(slot:FindFirstChild("TextLabelCost", true))
		-- A maxed brainrot has no price left on its button, so an unparsable or
		-- missing cost is the max check - there is no MAX_LEVEL constant in any
		-- config here (the highest seen on a plot was 36).
		if slot and prompt and cost and cost > 0 then
			local gain = entry.revenue * LEVEL_GAIN
			out[#out + 1] = {
				slot = entry.slot, node = slot, prompt = prompt, cost = cost,
				gain = gain, key = entry.key, level = entry.level,
				payback = cost / math.max(gain, 1),
			}
		end
	end
	table.sort(out, function(a, b) return a.payback < b.payback end)
	return out
end

local function upgradeBrainrots()
	local d = data()
	if not d then return false end
	local cash = num(d.currencies.cash)
	local candidates = upgradeCandidates()
	if #candidates == 0 then return false end

	-- Walk the ranking and buy everything that is affordable and pays for itself
	-- inside the cap, best rate first. One pass touches several slots, which is
	-- the difference to the first version - that one only ever levelled the
	-- single strongest brainrot and left every green button on the plot alone.
	local bought = 0
	for _, c in ipairs(candidates) do
		if _G.__JETPACK ~= generation then break end
		if bought >= CONFIG.upgradesPerPass then break end
		if c.payback <= CONFIG.paybackCap and c.cost <= cash then
			local cashBefore = num(data().currencies.cash)
			local genBefore = num(data().statistics.genPerSecond)
			STATE.phase = "levelling slot " .. tostring(c.slot)
			local ok, pivot = pcall(function() return c.node:GetPivot() end)
			if ok then
				withPin(function() return pivot + Vector3.new(0, 4, 0) end, function()
					task.wait(0.9)
					pcall(function() fireproximityprompt(c.prompt, 1) end)
					task.wait(0.8)
				end)
			end
			local d2 = data()
			local spent = cashBefore - (d2 and num(d2.currencies.cash) or cashBefore)
			local gained = (d2 and num(d2.statistics.genPerSecond) or genBefore) - genBefore
			if spent > 0 then
				bought = bought + 1
				cash = d2 and num(d2.currencies.cash) or cash
				STATE.upgrades = STATE.upgrades + 1
				STATE.upgradeSpend = STATE.upgradeSpend + spent
				note(string.format("slot %s %s lvl%d: -%s for +%s/s (%.0fs)",
					tostring(c.slot), tostring(c.key), c.level, short(spent),
					short(gained), spent / math.max(gained, 1)))
			end
		end
	end
	return bought > 0
end

-- Rebirth is gated on BOOST, nothing else, and the ladder comes from the game's
-- own RebirthConfigs: GetRequirements(n).boost is 60 for the first one, then 80,
-- 100, 120 (+15 from there), GetCost(0) is 0 and GetMoneyMultiplier(1) is 1.5.
-- Boost is bought with UpgradeBoost, so "rebirth" really means "buy boost until
-- the requirement is met, then fire it".
local RebirthConfigs
do
	for _, m in ipairs(Source:GetDescendants()) do
		if m:IsA("ModuleScript") and m.Name == "RebirthConfigs" then
			local ok, cfg = pcall(require, m)
			if ok then RebirthConfigs = cfg end
			break
		end
	end
end

-- GetRequirements is indexed by the rebirth you are buying, not the one you
-- hold: at 0 rebirths the panel reads "Boost 67/80" and GetRequirements(0) is 60
-- while GetRequirements(1) is 80. Off by one here means the script fires a
-- rebirth the server refuses, forever.
local function rebirthRequirement()
	local d = data()
	local rebirths = d and d.stats and d.stats.rebirths or 0
	if RebirthConfigs and RebirthConfigs.GetRequirements then
		local ok, req = pcall(RebirthConfigs.GetRequirements, rebirths + 1)
		if ok and type(req) == "table" and req.boost then return num(req.boost) end
	end
	return 80 + rebirths * 20
end

local function rebirthIfWorth()
	local d = data()
	if not d or not d.stats then return false end
	local boost = num(d.stats.boost)
	local need = rebirthRequirement()
	STATE.rebirthNeed = need
	if boost < need then
		note(string.format("rebirth wants boost %s, have %s - buying boost",
			short(need), short(boost)))
		-- UpgradeBoost takes a quantity; buying in tens closes a 13 point gap in
		-- two calls instead of thirteen.
		for _ = 1, 12 do
			if _G.__JETPACK ~= generation then break end
			local d1 = data()
			local missing = need - (d1 and num(d1.stats.boost) or 0)
			if missing <= 0 then break end
			local amount = missing >= 10 and 10 or 1
			if not buy("UpgradeBoost", "boost x" .. amount, amount) then break end
		end
		d = data()
		boost = d and num(d.stats.boost) or boost
		if boost < need then return false end
	end

	local before = { rebirths = d.stats.rebirths or 0, gen = d.statistics and num(d.statistics.genPerSecond) or 0 }

	-- The Rebirth remote answers and does nothing - same shape as the brainrot
	-- upgrade. The real path is the panel: open it from the left menu, then fire
	-- ButtonRebirth. **Never ButtonSkip** next to it, that is the Robux "Skip
	-- Rebirth / Keep Boost" product.
	local fired = false   -- wurde der Knopf wirklich gedrueckt?
	local gui = plr:FindFirstChild("PlayerGui")
	local main = gui and gui:FindFirstChild("MainGui")
	local window = main and main:FindFirstChild("Rebirth")
	if main and window then
		local menuEntry = main:FindFirstChild("Rebirth", true)
		local opener = main:FindFirstChild("HUDLeftSide")
		opener = opener and opener:FindFirstChild("Menu")
		opener = opener and opener:FindFirstChild("Menu")
		opener = opener and opener:FindFirstChild("Rebirth")
		opener = opener and opener:FindFirstChildWhichIsA("ImageButton")
		if opener and not window.Visible then
			local ok, conns = pcall(getconnections, opener.Activated)
			if ok then for _, c in ipairs(conns) do pcall(function() c:Fire() end) end end
			task.wait(1)
		end
		local button
		for _, node in ipairs(window:GetDescendants()) do
			if node.Name == "ButtonRebirth" then button = node end
		end
		if button then
			local ok, conns = pcall(getconnections, button.Activated)
			if ok then
				for _, c in ipairs(conns) do pcall(function() c:Fire() end) end
				fired = #conns > 0
			end
		end
		task.wait(1.5)
		-- Close it again; the interface should never be left open.
		local closeButton = window:FindFirstChild("CloseButton", true)
		if closeButton then
			local ok, conns = pcall(getconnections, closeButton.Activated)
			if ok then for _, c in ipairs(conns) do pcall(function() c:Fire() end) end end
		end
	end
	task.wait(1.5)
	local d2 = data()
	if d2 and d2.stats and (d2.stats.rebirths or 0) > before.rebirths then
		STATE.rebirthsDone = STATE.rebirthsDone + 1
		note(string.format("rebirth %d -> %d, income %s/s -> %s/s",
			before.rebirths, d2.stats.rebirths, short(before.gen),
			short(d2.statistics and num(d2.statistics.genPerSecond) or 0)))
		return true
	end
	-- "refused" is a claim about the SERVER, so only say it when the button was
	-- actually pressed. If the panel or the button was not found, nothing was
	-- ever sent - reporting that as a refusal sends the reader looking for a
	-- missing requirement instead of a missing GUI node.
	if not fired then
		note("rebirth: the panel button was not found - nothing was sent")
	else
		note("rebirth refused by the server")
	end
	return false
end

-- Loops ----------------------------------------------------------------------

local function loop(interval, key, fn)
	task.spawn(function()
		while _G.__JETPACK == generation do
			if CONFIG[key] then
				local ok, err = pcall(fn)
				if not ok then note(tostring(key) .. ": " .. tostring(err)) end
			end
			task.wait(interval)
		end
	end)
end

task.spawn(function()
	while _G.__JETPACK == generation do
		local d = data()
		if d then
			STATE.cash = num(d.currencies.cash)
			STATE.gen = d.statistics and num(d.statistics.genPerSecond) or 0
			STATE.level = d.stats and d.stats.level or 0
			STATE.rebirths = d.stats and d.stats.rebirths or 0
			STATE.boost = d.stats and d.stats.boost or 0
			if STATE.startCash == 0 and STATE.cash > 0 then STATE.startCash = STATE.cash end
		end
		STATE.slotsUsed = select(1, occupiedSlots())
		STATE.slotsTotal = #slotFolders()
		STATE.carrying = carrying()
		local placed = placedBrainrots()
		local worst, best = nil, 0
		for _, entry in ipairs(placed) do
			if not worst or entry.revenue < worst then worst = entry.revenue end
			if entry.revenue > best then best = entry.revenue end
		end
		STATE.worst, STATE.best = worst or 0, best
		STATE.rebirthNeed = rebirthRequirement()
		task.wait(1)
	end
end)

loop(1, "autoFarm", function()
	withUI("farm", farmCycle)
end)

loop(CONFIG.claimEvery, "autoClaim", claimAll)

loop(8, "autoUpgradeBrainrot", upgradeBrainrots)

loop(15, "autoUpgradeBase", function()
	buy("UpgradeBase", "base slot")
end)

loop(6, "autoBoost", function()
	buy("UpgradeBoost", "boost", 1)
end)

loop(30, "autoRebirth", function()
	rebirthIfWorth()
end)

loop(120, "autoFreeRewards", claimFreeRewards)

loop(45, "autoLuckyBlocks", function()
	if #heldLuckyBlocks() == 0 then return end
	withUI("lucky blocks", openLuckyBlocks)
end)

-- Panel ----------------------------------------------------------------------

local UI = (_G.__SEL and _G.__SEL.ui) or loadstring(readfile("ui-template.lua"))()

local win = UI.Window({
	name = PANEL_NAME,
	title = "JETPACK", accentTitle = "BRAINROTS", subtitle = "seltonmt",
	badge = "🚀", width = 920, height = 580,
})
_G.__JETPACK_WIN = win

local farmPage = win:Page("FARM", UI.icon.bolt)
local basePage = win:Page("BASE", UI.icon.grid)
local infoPage = win:Page("INFO", UI.icon.list)

local farmCard = farmPage:Card("COLLECT", 1)
farmCard:Toggle("Auto farm", CONFIG.autoFarm, function(v) CONFIG.autoFarm = v end,
	"warp to the best brainrot, pick it up, bring it home")
farmCard:Toggle("Auto place", CONFIG.autoPlace, function(v) CONFIG.autoPlace = v end,
	"fires the slot's PlacePrompt - it reports disabled and works anyway")
farmCard:Toggle("Fill empty slots first", CONFIG.fillFirst,
	function(v) CONFIG.fillFirst = v end, "stop farming once the base is full")
farmCard:Dropdown("Minimum rarity", RARITY_ORDER, RARITY_ORDER[CONFIG.minRarityIndex],
	function(v) CONFIG.minRarityIndex = RARITY_INDEX[v] or 1 end)
farmCard:Slider("Pickup settle (s x10)", 5, 30, math.floor(CONFIG.pickupSettle * 10),
	function(v) CONFIG.pickupSettle = v / 10 end)

local cashCard = farmPage:Card("CASH", 2)
cashCard:Toggle("Auto claim", CONFIG.autoClaim, function(v) CONFIG.autoClaim = v end,
	"ClaimEarnings per slot, plain remote, no walking")
cashCard:Slider("Claim every (s)", 5, 120, CONFIG.claimEvery, function(v)
	CONFIG.claimEvery = v
end)
cashCard:Toggle("Auto free rewards", CONFIG.autoFreeRewards,
	function(v) CONFIG.autoFreeRewards = v end, "offline, daily, playtime, group")
cashCard:Toggle("Auto lucky blocks", CONFIG.autoLuckyBlocks,
	function(v) CONFIG.autoLuckyBlocks = v end,
	"opens held blocks at the stand, reward is picked up by the farm")
cashCard:Button("Claim now", function() task.spawn(claimAll) end)
cashCard:Button("Open blocks now", function()
	task.spawn(function() withUI("lucky blocks", openLuckyBlocks) end)
end)

local upCard = basePage:Card("UPGRADES", 1)
upCard:Toggle("Auto level brainrots", CONFIG.autoUpgradeBrainrot,
	function(v) CONFIG.autoUpgradeBrainrot = v end, "UpgradeBrainrot per slot")
upCard:Toggle("Auto buy base slots", CONFIG.autoUpgradeBase,
	function(v) CONFIG.autoUpgradeBase = v end, "10 slots up to 40", UI.theme.warn)
upCard:Toggle("Auto boost", CONFIG.autoBoost, function(v) CONFIG.autoBoost = v end,
	"boost is flight range, which is rarity, which is income")
upCard:Button("Upgrade best once", function() task.spawn(upgradeBrainrots) end)

local rbCard = basePage:Card("REBIRTH", 2)
rbCard:Toggle("Auto rebirth", CONFIG.autoRebirth, function(v) CONFIG.autoRebirth = v end,
	"resets boost, keeps brainrots, +0.5 multiplier", UI.theme.warn)
rbCard:Button("Rebirth now", function() task.spawn(rebirthIfWorth) end, UI.theme.warn)

local readout = infoPage:Card("LIVE", 0):Readout(16)

-- Der Home-Tab: das GitHub-Commit-Log als Changelog plus der aktuelle Lauf.
-- Zuletzt deklariert, aber das Template schiebt ihn an den Anfang der Leiste -
-- er ist immer das erste Icon und die Seite, auf der das Panel aufgeht.
pcall(function() win:Home() end)

win:Refresh()

task.spawn(function()
	while _G.__JETPACK == generation do
		win:SetStatus(string.format("$%s   %s/s   lvl %d   rb %d   slots %d/%d   %s",
			short(STATE.cash), short(STATE.gen), STATE.level, STATE.rebirths,
			STATE.slotsUsed, STATE.slotsTotal, STATE.phase))
		readout:set({
			"ECONOMY",
			string.format("  cash       $%s", short(STATE.cash)),
			string.format("  income     %s/s", short(STATE.gen)),
			string.format("  claimed    %s in %d passes", short(STATE.claimed), STATE.claims),
			string.format("  boost      %s", short(STATE.boost)),
			"FARM",
			string.format("  target     %s", STATE.target),
			string.format("  picked     %d   placed %d", STATE.picked, STATE.placed),
			string.format("  carrying   %s", tostring(STATE.carrying)),
			string.format("  slots      %d of %d used", STATE.slotsUsed, STATE.slotsTotal),
			string.format("  plot       worst %s/s, best %s/s", short(STATE.worst), short(STATE.best)),
			string.format("  swaps      %d replaced, %d left alone", STATE.replaced, STATE.skipped),
			"SPENDING",
			string.format("  upgrades   %d for %s", STATE.upgrades, short(STATE.upgradeSpend)),
			string.format("  rebirths   %d done, next needs boost %s (have %s)",
				STATE.rebirthsDone, short(STATE.rebirthNeed), short(STATE.boost)),
			string.format("  runtime    %dm", math.floor((os.clock() - STATE.startedAt) / 60)),
			"NOTE",
			"  " .. tostring(STATE.note),
		})
		task.wait(1)
	end
end)

_G.__JETPACK_DBG = {
	CONFIG = CONFIG, STATE = STATE,
	data = data, num = num, findStore = findStore, remote = remote, invoke = invoke,
	myBase = myBase, freeSlot = freeSlot, occupiedSlots = occupiedSlots,
	bestBrainrot = bestBrainrot, pickUp = pickUp, placeCarried = placeCarried,
	placedBrainrots = placedBrainrots, weakestPlaced = weakestPlaced,
	inventoryBrainrots = inventoryBrainrots, slotByName = slotByName,
	rebirthRequirement = rebirthRequirement,
	farmCycle = farmCycle, claimAll = claimAll, claimFreeRewards = claimFreeRewards,
	crossLine = crossLine,
	upgradeBrainrots = upgradeBrainrots, rebirthIfWorth = rebirthIfWorth, buy = buy,
	upgradeCandidates = upgradeCandidates, labelNumber = labelNumber,
	reconcilePlot = reconcilePlot, sellJunkInventory = sellJunkInventory,
	keepers = keepers, lockKeepers = lockKeepers, unlockAll = unlockAll,
	heldLuckyBlocks = heldLuckyBlocks, openLuckyBlocks = openLuckyBlocks,
	rarityOf = rarityOf, rarityValue = rarityValue,
}

print("[jetpackbrainrots] loaded (gen " .. generation .. ") - RightShift toggles the panel")
