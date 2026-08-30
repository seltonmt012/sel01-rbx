-- islandescape.lua - Mrbeast Island Escape (108645230905176)
-- Round-based co-op survival. See .claude/docs/games-survival.md
--
-- The round is thrown away at the end; only Diamonds carry over, and escaping
-- pays 2. So this script optimises ROUNDS PER HOUR, not resources per minute:
-- fell -> collect -> craft the tool ladder -> build the boat -> escape.

-- Breadcrumb for load hangs. `bridge.py file` runs a script INLINE inside the
-- poll loop, so anything that yields at module level parks the bridge and every
-- later CLI call answers "no client answered". Read _G.__ISLAND_STEP to see how
-- far it got.
_G.__ISLAND_STEP = "start"

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local plr = Players.LocalPlayer

--------------------------------------------------------------------------- gen
local GEN = (_G.__ISLAND or 0) + 1
_G.__ISLAND = GEN
local function live() return _G.__ISLAND == GEN end

------------------------------------------------------------------------ config
local CONFIG = {
	auto            = false,
	farmWood        = true,
	farmStone       = true,
	farmIron        = true,
	autoCollect     = true,
	autoChests      = true,
	autoQuest       = true,
	autoParts       = true,
	chestGapWhenBusy = 45,
	autoCraft       = true,
	autoBuild       = true,
	autoBoat        = true,
	autoSmelt       = true,
	autoEscape      = false,
	redeemCodes     = true,
	fastHarvest     = true,
	autoDefend      = true,
	defendRadius    = 60,
	fleeAtHp        = 35,
	noDamage        = false,
	hoverAtNight    = true,
	hoverHeight     = 14,
	evadeShadow     = true,
	shadowFleeRadius = 220,   -- known-about distance
	shadowPanicRadius = 70,   -- run even at full health inside this
	shadowFleeHp     = 45,    -- below this, run as soon as it is known about
	onlyNeeded      = true,
	autoTidy        = true,
	autoChoice      = true,
	autoEat         = true,
	autoHunt        = true,
	keepFireLit     = true,
	nightSafety     = false,
	eatBelowHunger  = 70,
	autoRejoin      = false,
	autoLobbyOnDeath = true,
	rejoinCooldown  = 20,
	partySize       = 1,
	settleTime      = 0.9,
	maxEntries      = 40,
}

local STATE = {
	note      = "idle",
	day       = 0,
	phase     = "-",
	remain    = 0,
	bag       = 0,
	groundY   = 0,
	felled    = 0,
	collected = 0,
	guarded   = 0,
	built     = {},
	uiOwner   = nil,
	escapes   = 0,
}

----------------------------------------------------------------------- helpers
-- WaitForChild with NO timeout yields forever when the child never appears, and
-- an inline-executed script that yields parks the bridge's poll loop. Always
-- pass a timeout here and fail loudly instead.
_G.__ISLAND_STEP = "waiting for Engine"
local EngineFolder = ReplicatedStorage:WaitForChild("Engine", 10)
if not EngineFolder then
	_G.__ISLAND_STEP = "no ReplicatedStorage.Engine - wrong game?"
	error("islandescape: ReplicatedStorage.Engine missing", 0)
end
_G.__ISLAND_STEP = "waiting for Service"
local E = EngineFolder:WaitForChild("Service", 10)
if not E then
	_G.__ISLAND_STEP = "no Engine.Service"
	error("islandescape: Engine.Service missing", 0)
end
_G.__ISLAND_STEP = "waiting for Events"
local Events = ReplicatedStorage:WaitForChild("Events", 10)
if not Events then
	_G.__ISLAND_STEP = "no ReplicatedStorage.Events"
	error("islandescape: ReplicatedStorage.Events missing", 0)
end
_G.__ISLAND_STEP = "services found"

-- `require` can YIELD FOREVER, and that is not hypothetical here: requiring
-- Engine.Service.Furnace never returns. Loaded inline by `bridge.py file` that
-- parks the bridge's poll loop and every later CLI call answers "no client
-- answered"; loaded in a task.spawn it silently never finishes and the script
-- looks like it did nothing. Measured 2026-08-27 - the other nine services all
-- resolve instantly.
--
-- So no require is ever awaited on the main thread. Each one runs in its own
-- thread behind a wall-clock cap; a module that hangs costs its own feature and
-- nothing else.
local function svc(name, timeout)
	local inst = E:FindFirstChild(name)
	if not inst then return nil end
	local done, result = false, nil
	task.spawn(function()
		local ok, m = pcall(require, inst)
		result = (ok and type(m) == "table") and m or nil
		done = true
	end)
	local deadline = os.clock() + (timeout or 2)
	while not done and os.clock() < deadline do task.wait(0.05) end
	if not done then
		STATE.note = "service " .. name .. " hangs on require - skipped"
		return nil
	end
	return result
end

_G.__ISLAND_STEP = "requiring Config"
local Config       = (function() local ok, m = pcall(require, E:FindFirstChild("Config")) return ok and m or nil end)()
_G.__ISLAND_STEP = "requiring services"
local ItemCollect  = svc("ItemCollect")
local CraftItems   = svc("CraftItems")
local BuildBuilding= svc("BuildBuilding")
local PlayerInv    = svc("PlayerInventory")
local GameResult   = svc("GameResult")
local Furnace      = svc("Furnace")

-- The round world. Lobby and round share one PlaceId and differ only by folder.
local function round()   return workspace:FindFirstChild("Game") end
local function inLobby() return workspace:FindFirstChild("Lobby") ~= nil end

local function char() return plr.Character end
local function hum()
	local c = char()
	return c and c:FindFirstChildOfClass("Humanoid") or nil
end
local function alive()
	local h = hum()
	return h ~= nil and h.Health > 0
end
local function hrp()
	local c = char()
	return c and c:FindFirstChild("HumanoidRootPart") or nil
end

-- HOLD STILL: escape cutscene, result screen, death screen.
--
-- Escaping does NOT remove Workspace.Game. The boat cutscene and the result
-- screen play out with the round folder still in place, so every loop carried
-- on as though nothing had happened: nextNode found nothing streamed in where
-- the boat had carried us, the farm fell through to its "relocating" branch and
-- teleported the character back across the map - which is what kept cutting the
-- escape cutscene off. The player watched it happen and it is not subtle.
--
-- These four ScreenGuis carry those moments - but `Enabled` IS NOT THE SIGNAL.
-- Measured on a live client in the middle of a perfectly normal Day 1: all four
-- sit at Enabled=true permanently and hide themselves with their top frame
-- instead (GameResult.bg.Visible=false, BlackScreen.Frame.Visible=false, and so
-- on). Reading Enabled therefore reported "round over" every single tick and
-- halted the entire script - the panel said "round over (GameResult) - holding
-- still" while the round was four seconds old. The frame is the truth.
local HALT_GUIS = { "GameResult", "BlackScreen", "Story", "DeathScreen" }

local function cutscene()
	local pg = plr:FindFirstChildOfClass("PlayerGui")
	if not pg then return false end
	for _, n in ipairs(HALT_GUIS) do
		local g = pg:FindFirstChild(n)
		if g and g:IsA("ScreenGui") and g.Enabled then
			for _, ch in ipairs(g:GetChildren()) do
				if ch:IsA("GuiObject") and ch.Visible then return true, n end
			end
		end
	end
	return false
end

-- A real log, not just the one-line status. Every decision that skips work
-- writes WHY here, because "it teleports around and does nothing" is impossible
-- to debug from a single note field - which is exactly how this script burned
-- an afternoon.
STATE.log = {}
STATE.counts = {}
local lastLog = nil
local function log(fmt, ...)
	local ok, s = pcall(string.format, fmt, ...)
	if not ok then s = tostring(fmt) end
	local t = STATE.log

	-- Count every kind of line for the whole run, so the picture survives the
	-- ring buffer. Without this the log filled with 57 copies of the same
	-- "night - holding" and said nothing about where the time actually went.
	local key = s:gsub("%d+", "N")
	STATE.counts[key] = (STATE.counts[key] or 0) + 1

	-- Collapse repeats instead of flooding.
	if lastLog == s then
		local last = t[#t]
		local base, n = tostring(last):match("^(.-) x(%d+)$")
		if base == s then t[#t] = s .. " x" .. (tonumber(n) + 1)
		else t[#t] = s .. " x2" end
		return
	end
	lastLog = s
	t[#t + 1] = s
	while #t > 60 do table.remove(t, 1) end
end

local function note(s) STATE.note = s log("%s", s) end

-- Run a real GuiButton's own handler rather than guessing at its remote. This
-- is the path that solved the death screen and the party dialog on the first
-- try each; see .claude/docs/reverse-engineering.md.
-- BOTH events, and that is not belt-and-braces. Measured on the MrBeast choice
-- panel: its ReceiveButton carries exactly one connection on Activated AND one
-- on MouseButton1Click, and firing Activated alone did NOTHING - the panel
-- stayed open and the loop re-fired it every two seconds, logging a successful
-- pick while nothing was ever picked. One MouseButton1Click took the cell count
-- from 1 to 0 and closed it.
--
-- This function presses every button in the script - the lobby button when
-- dead, the collect prompts, the chest buttons - so firing only Activated was a
-- silent partial failure everywhere, not just on that one panel.
local function press(btn)
	if not btn then return 0 end
	local n = 0
	for _, ev in ipairs({ "MouseButton1Click", "Activated" }) do
		local ok, conns = pcall(function() return getconnections(btn[ev]) end)
		if ok and conns then
			for _, c in ipairs(conns) do
				pcall(function() c:Fire() end)
				n = n + 1
			end
		end
	end
	return n
end

-- Every setter is called with a colon on the UI side; keep plain functions here.
local function nodePart(m)
	if not m or not m.Parent then return nil end
	return m:FindFirstChild("BoundingBox") or m.PrimaryPart or m:FindFirstChildWhichIsA("BasePart", true)
end

-- Tool the character is holding, plus its config row.
local toolByName
local function toolRow(name)
	if not toolByName and Config and Config.tool then
		toolByName = Config.tool.byDisplayName or {}
	end
	local r = toolByName and toolByName[name]
	if type(r) == "table" and r.toolType then return r end
	return nil
end

local function equippedTool()
	local c = char()
	local t = c and c:FindFirstChildOfClass("Tool")
	if not t then return nil, nil end
	return t, toolRow(t.Name)
end

-- Every tool we own, best `useDmg` first, keyed by the toolType the resource
-- config asks for. The axe usually sits in the BACKPACK rather than the hand,
-- and an unequipped tool makes every node look unharvestable - which reads as
-- "no reachable node" and stalls the whole farm.
local function ownedTools()
	local out = {}
	local c = char()
	local list = {}
	if c then for _, t in ipairs(c:GetChildren()) do if t:IsA("Tool") then list[#list+1] = t end end end
	for _, t in ipairs(plr.Backpack:GetChildren()) do if t:IsA("Tool") then list[#list+1] = t end end
	for _, t in ipairs(list) do
		local row = toolRow(t.Name)
		if row then
			local cur = out[row.toolType]
			if not cur or (row.useDmg or 0) > (cur.row.useDmg or 0) then
				out[row.toolType] = { tool = t, row = row }
			end
		end
	end
	return out
end

-- Returns the tool row actually in hand afterwards, or nil if we own nothing
-- that fits.
local function equipFor(toolType)
	local t, row = equippedTool()
	if row and (toolType == "any" or row.toolType == toolType) then return row end
	local owned = ownedTools()
	local pick = owned[toolType]
	if not pick and toolType == "any" then
		for _, v in pairs(owned) do pick = v break end
	end
	if not pick then return nil end
	local h = hum()
	if not h then return nil end
	pcall(function() h:EquipTool(pick.tool) end)
	task.wait(0.25)
	local _, nowRow = equippedTool()
	return nowRow
end

local resById
local function resourceRow(id)
	if not resById and Config and Config.worldResource then
		resById = Config.worldResource.byId or {}
	end
	return resById and resById[id] or nil
end

-- One hand, one owner. The bodyguard equips food to eat and a weapon to swing,
-- the farm equips an axe or a pickaxe - and they run in separate threads. With
-- no lock the guard swapped Meat into the hand during the farm's 0.9s settle
-- wait, so the swing that followed hit a tree with a piece of meat and did
-- nothing: node hp 90 -> 90, no drops, "picked 0". Measured 2026-08-27.
--
-- Same rule as withUI in the other scripts here: whoever holds it finishes.
local hand = { owner = nil, since = 0 }

-- waitSecs: how long this caller is willing to queue. The bodyguard equips for
-- ~0.2s every 0.35s, so a farm that gives up instantly loses most of its
-- attempts to "busy: defend" - measured, three swings in a row refused while
-- the axe was already in hand. The long operation waits; the short one does not.
local function withHand(name, fn, waitSecs)
	local deadline = os.clock() + (waitSecs or 0)
	while hand.owner and hand.owner ~= name do
		-- Never wedge forever if a holder died mid-action.
		if os.clock() - hand.since > 20 then break end
		if os.clock() >= deadline then return false, "busy: " .. hand.owner end
		task.wait(0.05)
	end
	hand.owner, hand.since = name, os.clock()
	local ok, err = pcall(fn)
	hand.owner = nil
	if not ok then return false, tostring(err) end
	return true
end

-- Forward declaration: fellNode collects while still pinned at the node, but
-- collectDrops is defined further down. Lua locals are invisible above their
-- definition and every call here sits inside a pcall, so without this the
-- collect step fails as a quiet "attempt to call a nil value" in the status
-- line - the same trap that already cost this script two debugging rounds.
-- Forward declarations. This file has now hit the "Lua locals are invisible
-- above their definition" trap FOUR times - bagCap, collectDrops,
-- pendingConstructs and these two - and every single time the pcall around the
-- caller turned it into a quiet status-line note instead of a crash. Anything
-- fellNode or the guard reaches for gets declared here.
local collectDrops
local neededStock
local foodRowForTool
-- The pickup policy. Defined down with hunger() and foodRowForTool because it
-- needs both, used up here by fellNode - so it gets a forward declaration like
-- everything else rather than a fifth visit to that trap.
local wantFilter
local dropSkipped
local skipDrop

-------------------------------------------------------------- the harvest core
-- meleeHitRemote:FireServer(mobArray, resourceArray). BOTH are arrays; the
-- server applies damage per entry and enforces neither capAOE nor a cooldown,
-- so one call with the node repeated ceil(hp/useDmg) times fells it outright.
-- What it DOES enforce: ~2x the tool's range, the correct tool type, and that
-- the player is alive.
local function hitsNeeded(node, toolCfg)
	local hp  = node:GetAttribute("hp") or 90
	local dmg = (toolCfg and toolCfg.useDmg) or 11
	if dmg <= 0 then dmg = 1 end
	local n = math.ceil(hp / dmg) + 1
	if not CONFIG.fastHarvest then n = 1 end
	return math.clamp(n, 1, CONFIG.maxEntries)
end

-- Pin the character next to a point for `secs`, aborting the moment it dies.
-- The server validates against ITS copy of the position, so the settle wait is
-- load-bearing: firing 0.3s after the warp misses, ~0.9s is reliable.
-- `stay`: leave the character where the work happened instead of snapping back.
-- Restoring the origin after every node made the body bounce between the tree
-- and wherever it started, twice per harvest, which is what the player saw as
-- "er teleportiert die ganze Zeit hin und her".
local function withPin(pos, secs, fn, stay)
	-- Every teleport in this script goes through here, so this one line is what
	-- keeps the body still through the escape cutscene and the result screen.
	if cutscene() then return false, "cutscene" end
	local root = hrp()
	if not root or not alive() then return false, "dead" end
	local origin = root.CFrame
	local target = CFrame.new(pos + Vector3.new(0, 3, 8), pos)
	local pinned = true
	local conn = RunService.Heartbeat:Connect(function()
		if pinned and root.Parent then root.CFrame = target end
	end)
	local ok, err = pcall(function()
		task.wait(secs or CONFIG.settleTime)
		if not alive() then error("died while settling", 0) end
		fn()
	end)
	pinned = false
	conn:Disconnect()
	if not stay and root.Parent then root.CFrame = origin end
	return ok, err
end

local function fellNode(node)
	if not alive() then return false, "dead" end
	local part = nodePart(node)
	if not part then return false, "gone" end

	-- Tool type IS enforced server-side, so put the right one in hand first, and
	-- hold the hand for the whole swing so the bodyguard cannot swap food in
	-- during the settle wait.
	local res = resourceRow(node:GetAttribute("resourceId"))
	local picked, fired = 0, false
	local held, why = withHand("farm", function()
		local toolCfg = equipFor(res and res.requireToolType or "any")
		if not toolCfg then error("no tool for " .. tostring(res and res.requireToolType), 0) end
		local n = hitsNeeded(node, toolCfg)
		local arr = table.create(n, node)

		-- Collect INSIDE the pin. misc.collectRadius is 12 and the server checks
		-- it against its own copy of our position, so felling, warping home and
		-- then sweeping picks up nothing: every call is refused in silence. That
		-- is what produced "46 collected" against a bag that went DOWN.
		-- Pick up only what is still wanted plus anything edible. Five bag slots
		-- filled with Iron Ore and Eggs nobody needs is how the farm ends up
		-- staring at "Insufficient Materials".
		local filter = wantFilter

		local ok, pinErr = withPin(part.Position, CONFIG.settleTime, function()
			Events.meleeHitRemote:FireServer({}, arr)
			fired = true
			task.wait(0.6)
			if CONFIG.autoCollect then picked = collectDrops(part.Position, 30, filter) end
		end, true)
		-- Propagate the REAL reason. Collapsing it to "pin failed" hid the
		-- actual error for a whole debugging round.
		if not ok then error("pin: " .. tostring(pinErr), 0) end
	end, 3)
	if not held then return false, why, picked end
	if not fired then return false, "never fired", picked end

	local after = node.Parent and node:GetAttribute("hp") or 0
	if (after or 0) <= 0 or not node.Parent then
		STATE.felled = STATE.felled + 1
		return true, nil, picked
	end
	return false, "hp still " .. tostring(after), picked
end

------------------------------------------------------------------- inventory
-- Defined BEFORE collectDrops on purpose. Lua locals are invisible above their
-- definition, and every call here sits inside a pcall, so having bagCap() below
-- its caller produced a quiet "attempt to call a nil value" in the status line
-- instead of a crash - the exact trap in .claude/docs/traps.md.
local function bagCount()
	if not PlayerInv or not PlayerInv.client then return 0 end
	local ok, v = pcall(PlayerInv.client.getBagItemCount, plr)
	if ok and type(v) == "number" then return v end
	return 0
end

-- The bag is the real bottleneck: bag_0 holds FIVE. Once it is full the server
-- refuses every pickup in silence, so a sweep that ignores the cap spins
-- forever and reports success on refusals.
local function bagCap()
	if PlayerInv and PlayerInv.getBagCap then
		local ok, v = pcall(PlayerInv.getBagCap, plr)
		if ok and type(v) == "number" and v > 0 then return v end
	end
	local id = plr:GetAttribute("bagId") or "bag_0"
	local row = Config and Config.bag and Config.bag.byId and Config.bag.byId[id]
	local cap = (type(row) == "table" and row.cap) or 5
	return cap + (plr:GetAttribute("bagSlotsBonus") or 0)
end

local function bagFull() return bagCount() >= bagCap() end

-- Is this bag entry a MATERIAL STACK - something that costs bag slots and can be
-- dropped or stored - rather than a tool, a weapon, armour or a bag?
--
-- This replaces a `GetAttribute("count")` test that was quietly wrong. Measured
-- on a live bag: NOT ONE Tool carries a `count` attribute while its stack is a
-- single item - Spider Web, Iron Ore, Stone Axe and Wooden Spear all read nil,
-- and the attribute only appears once a stack passes one. Every unload path was
-- gated on it, so with a bag full of singles dropStack, storeSurplus and the
-- tidy pass all matched NOTHING.
--
-- That is the real story behind the 44 logged "bag full and nothing to unload"
-- lines, and behind the Spider Web the player kept finding in a bag that called
-- itself full: the script could see the junk and agreed it was junk, but had no
-- way to name it as droppable. Classify by the game's own item tables instead -
-- an item that is not a tool, not armour and not a bag is cargo.
local function stackItem(name)
	if not Config then return false end
	local tool = Config.tool and Config.tool.byDisplayName
	if tool and tool[name] then return false end
	local arm = Config.armour and Config.armour.byDisplayName
	if arm and arm[name] then return false end
	-- Never throw the bag away; it has no byDisplayName index, so match the list.
	for _, r in ipairs((Config.bag and Config.bag.list) or {}) do
		if r.displayName == name then return false end
	end
	local item = Config.item and Config.item.byDisplayName
	return (item and item[name]) ~= nil
end

-- Throw a stack on the ground. Same mechanism as handing an item to MrBeast:
-- equip it and HOLD F past misc.confirmDropSec. This is the fallback for a full
-- bag before Storage exists - the log filled with 64 copies of "bag full and
-- nothing to unload" because burning needs a campfire and storing needs a
-- Storage, and early on there is neither. Dropped items stay in the world, so
-- nothing is lost: they can be picked up again when they are wanted.
local VIM_ = game:GetService("VirtualInputManager")

-- ONE hold of F drops ONE item, not the stack. bagCount() counts a stack's
-- CONTENTS - a 4x Egg stack is four of the five slots - so a single hold freed
-- one quarter of what it looked like it freed and the bag was full again on the
-- next node. That is the "he puts down one although he is carrying more" the
-- player reported, and the log agrees: four separate "dropped N (Egg)" lines.
-- So hold F until the stack is actually gone, and blacklist the name afterwards
-- so the sweep does not simply carry it home again.
local function dropStack(toolName)
	local function findTool()
		-- BOTH places. Equipping moves the Tool out of the Backpack and into the
		-- Character, so a search that only looked in the Backpack found nothing
		-- straight after the equip and broke out of the loop before pressing
		-- anything at all - measured, dropStack("Spider Web") returned -1 in
		-- 0.9s having never sent a single key event.
		local places = { plr.Backpack }
		local c = char()
		if c then places[#places + 1] = c end
		for _, parent in ipairs(places) do
			for _, t in ipairs(parent:GetChildren()) do
				if t:IsA("Tool") and (not toolName or t.Name == toolName) and stackItem(t.Name) then
					return t
				end
			end
		end
		return nil
	end

	local tool = findTool()
	if not tool then return 0, "nothing droppable" end
	local h = hum()
	if not h then return 0, "no humanoid" end
	local name   = tool.Name
	local before = bagCount()

	-- THE REAL PATH: PlayerInventory.client.dropItem(tool). No key press, no
	-- window focus, no equip - measured, bag 3 -> 2 with the Egg gone in about a
	-- second. The project notes list dropItem as a dead end, and that is true of
	-- the case it was measured for (handing an item to MrBeast, which needs the
	-- held F); for simply freeing a slot it is exactly right, and it is the only
	-- version of this that works while the game window is not in front.
	if PlayerInv and PlayerInv.client and PlayerInv.client.dropItem then
		for _ = 1, 8 do
			if not live() then break end
			local t = findTool()
			if not t or t.Name ~= name then break end
			local now = bagCount()
			pcall(PlayerInv.client.dropItem, t)
			task.wait(0.35)
			if bagCount() >= now then break end
		end
		local got = before - bagCount()
		if got > 0 then
			skipDrop(name, 90)
			log("dropped %d (%s)", got, name)
			return got
		end
	end

	-- Fallback: the held F, which is what this used before the API was found.
	pcall(function() h:UnequipTools() end)
	task.wait(0.25)
	pcall(function() h:EquipTool(tool) end)
	task.wait(0.6)

	-- Five slots is the whole bag, so six holds can always empty one stack.
	-- Stop early on a hold that frees nothing rather than burning ten seconds
	-- against an item the server will not let go of.
	local stall = 0
	for _ = 1, 6 do
		if not live() then break end
		local now = bagCount()
		local t = findTool()
		if not t or t.Name ~= name then break end
		pcall(function()
			VIM_:SendKeyEvent(true, Enum.KeyCode.F, false, game)
			task.wait(1.3)
			VIM_:SendKeyEvent(false, Enum.KeyCode.F, false, game)
		end)
		task.wait(0.6)
		if bagCount() >= now then
			stall = stall + 1
			if stall >= 2 then break end
		else
			stall = 0
		end
	end

	local freed = before - bagCount()
	if freed > 0 then
		skipDrop(name, 90)
		log("dropped %d (%s)", freed, name)
	end
	return freed
end

-- Bag items are STACKS: a Tool with a `count` attribute. Stone count=8 plus
-- Iron Ingot count=5 plus one Iron Ore is a bag of 14, not of 3 - and treating
-- every Tool as one item is what made the "what am I short of" logic pick the
-- wrong material for hours.
local function bagContents()
	local out = {}
	local function add(t)
		if not t:IsA("Tool") then return end
		out[t.Name] = (out[t.Name] or 0) + (t:GetAttribute("count") or 1)
	end
	for _, t in ipairs(plr.Backpack:GetChildren()) do add(t) end
	local c = char()
	if c then for _, t in ipairs(c:GetChildren()) do add(t) end end
	return out
end

-- Storage holds 20 and is the right home for anything the build plan does not
-- want right now. Verified: storeItem(tool) moved a stack of 8 Stone out of the
-- bag (14 -> 6) and it showed up in getSnapshot as {count=8, "Stone"}.
local Storage = svc("Storage")

local function storeSurplus(keep)
	if not Storage or not Storage.client then return 0, "no storage service" end
	local G = round()
	local b = G and G:FindFirstChild("Buildings")
	local store = b and b:FindFirstChild("Storage")
	local part = store and store:FindFirstChildWhichIsA("BasePart", true)
	if not part then return 0, "storage not built" end

	local moved = 0
	withPin(part.Position, CONFIG.settleTime, function()
		for _, t in ipairs(plr.Backpack:GetChildren()) do
			if not live() then break end
			if t:IsA("Tool") and not keep[t.Name] and stackItem(t.Name) then
				local before = bagCount()
				pcall(Storage.client.storeItem, t)
				task.wait(0.5)
				local d = before - bagCount()
				if d > 0 then moved = moved + d log("stored %dx %s", d, t.Name) end
			end
		end
	end, true)
	return moved
end

----------------------------------------------------------------- drop pickup
-- Names the sweep leaves alone for a while. Needed twice over:
--
--  * WHAT WE JUST THREW AWAY. dropStack puts a stack on the ground to free
--    slots, and the very next sweep picked it straight back up. The log shows
--    "dropped N (Egg)" four separate times against a bag that never got any
--    emptier - the player saw it as "he puts one down and then picks it up
--    again".
--  * WHAT THE SERVER KEEPS REFUSING. Armour worse than what is worn comes back
--    as "I already have a better armour" in a speech bubble, three on screen at
--    once, forever - because the sweep rebuilds its candidate list every pass
--    and tries the same lump again. Counting misses per SWEEP cannot fix that;
--    the next sweep starts counting from zero.
local skipUntil, refusals = {}, {}

skipDrop = function(name, sec)
	if not name then return end
	skipUntil[name] = math.max(skipUntil[name] or 0, os.clock() + (sec or 45))
end

dropSkipped = function(name)
	return (skipUntil[name] or 0) > os.clock()
end

local function refusedDrop(name)
	if not name then return end
	refusals[name] = (refusals[name] or 0) + 1
	if refusals[name] >= 2 then
		-- Twice is not bad luck. Armour never becomes collectable again inside
		-- one round, so that one is parked for the round rather than a minute.
		local armour = Config and Config.armour and Config.armour.byDisplayName
		skipDrop(name, (armour and armour[name]) and 3600 or 60)
		refusals[name] = 0
	end
end

-- `wantOnly`: an optional predicate on the drop's Name. Sweeping blind is what
-- starved a character to death - huntFood killed a chicken, then the sweep
-- filled all five bag slots with Wood that happened to be lying nearby, the
-- meat was refused for lack of room, and hunger went to 0 with HP following.
function collectDrops(nearPos, radius, wantOnly)
	local G = round()
	if not G or not ItemCollect then return 0 end
	local folder = G:FindFirstChild("DroppedItems")
	if not folder then return 0 end
	local root = hrp()
	local from = nearPos or (root and root.Position)
	if not from then return 0 end
	-- pcall succeeding proves nothing - a refused pickup returns just as
	-- cleanly and leaves the drop lying there. Count the BAG, not the calls.
	local got, misses = 0, 0
	local cap = bagCap()
	local root = hrp()

	-- Build the candidate list first, nearest last, so we can walk it.
	local list = {}
	for _, m in ipairs(folder:GetChildren()) do
		local p = m:FindFirstChildWhichIsA("BasePart", true)
		if p and (p.Position - from).Magnitude <= (radius or 45)
		   and not dropSkipped(m.Name)
		   and (not wantOnly or wantOnly(m.Name)) then
			list[#list + 1] = { model = m, part = p }
		end
	end
	table.sort(list, function(a, b)
		return (a.part.Position - from).Magnitude < (b.part.Position - from).Magnitude
	end)

	for _, e in ipairs(list) do
		if not live() then break end
		local have = bagCount()
		if have >= cap then STATE.note = "bag full" break end
		if not e.model.Parent then continue end

		-- misc.collectRadius is 12 and the server measures from ITS copy of our
		-- position. Chest loot and mob drops scatter well past that, so reaching
		-- from where we happen to stand silently loses most of it - which is
		-- exactly what "you open chests but do not pick everything up" was.
		-- Step to anything out of reach instead.
		local dist = root and (e.part.Position - root.Position).Magnitude or 999
		if dist > 10 then
			withPin(e.part.Position, 0.45, function()
				pcall(ItemCollect.client.collect, e.model)
				task.wait(0.2)
			end, true)
			root = hrp()
		else
			pcall(ItemCollect.client.collect, e.model)
			task.wait(0.12)
		end

		-- A pickup can succeed WITHOUT the bag moving: armour auto-equips
		-- (misc.useArmourCollectEquip) and a tool goes to the backpack, and
		-- neither costs a bag slot. Judging by the bag alone counted both as
		-- refusals and blacklisted the very upgrades the tool ladder waits on.
		-- The model leaving DroppedItems is the honest signal.
		if bagCount() > have or not e.model.Parent then
			got = got + 1
			STATE.collected = STATE.collected + 1
			refusals[e.model.Name] = nil
			misses = 0
		else
			-- Several refusals in a row means the bag is full or these drops
			-- are not ours; stop rather than spin.
			refusedDrop(e.model.Name)
			misses = misses + 1
			if misses >= 4 then break end
		end
	end
	return got
end

-------------------------------------------------------------------- defence
-- Keeping the character alive is a precondition for every other measurement:
-- a dead player is refused by every remote in silence, which reads exactly like
-- a server-side gate. See .claude/docs/traps.md.
--
-- The Shadow carries 1,000,000 HP and is meant to be outlasted, not fought.
-- Anything at or above this is not a kill target.
local UNKILLABLE_HP = 100000

-- MELEE only. `meleeHitRemote` is the swing path; guns and thrown weapons go
-- through shootRemote / rangedFireRemote with a projectile and ammo, so picking
-- purely by atkDmg hands the guard a Shotgun (200) that it then "swings" at a
-- mob through the wrong remote and does nothing. Loot boxes hand out guns
-- freely, so this matters as soon as chest looting is on.
local MELEE_TYPES = { sword = true, axe = true, pickaxe = true }

local function bestWeapon()
	local owned = ownedTools()
	local best
	for _, v in pairs(owned) do
		if MELEE_TYPES[v.row.toolType] and (v.row.atkDmg or 0) > 0 then
			if not best or (v.row.atkDmg or 0) > (best.row.atkDmg or 0) then best = v end
		end
	end
	return best
end

-- Hunger, not mobs, is what actually kills an idle character here. It lives as
-- an ATTRIBUTE ON THE HUMANOID (`hunger` / `maxHunger`), not on the player and
-- not in leaderstats. Health only regenerates above misc.slowRegenThreshold
-- (50%) and regenerates twice as fast above fastRegenThreshold (80%), so a
-- character sitting at hunger 21 simply never heals - measured, HP stuck at 22
-- with zero drain and one harmless crab 79 studs away.
local function hunger()
	local h = hum()
	if not h then return 0, 100 end
	return h:GetAttribute("hunger") or 0, h:GetAttribute("maxHunger") or 100
end

-- Tool name -> food row, via item.byDisplayName -> food.byId.
function foodRowForTool(name)
	if not Config or not Config.item or not Config.food then return nil end
	local item = Config.item.byDisplayName and Config.item.byDisplayName[name]
	if type(item) ~= "table" or not item.id then return nil end
	local row = Config.food.byId and Config.food.byId[item.id]
	if type(row) == "table" and (row.hungerRegen or 0) > 0 then return row end
	return nil
end

local function foodInBag()
	local out = {}
	local c = char()
	local list = {}
	if c then for _, t in ipairs(c:GetChildren()) do if t:IsA("Tool") then list[#list+1] = t end end end
	for _, t in ipairs(plr.Backpack:GetChildren()) do if t:IsA("Tool") then list[#list+1] = t end end
	for _, t in ipairs(list) do
		local row = foodRowForTool(t.Name)
		if row then out[#out+1] = { tool = t, row = row } end
	end
	return out
end

------------------------------------------------------------ what to carry
-- The bag is FIVE slots and the round is lost in them. One screenshot, taken
-- while the farm was "working": 2x Stone, then Meat, an Egg and a Spider Web -
-- three of five slots on things no recipe, no meal and no tool has any use for,
-- while the furnace sat at 0/10 stone and the screen filled with red
-- "Insufficient Materials".
--
-- TOOLS AND ARMOUR ARE FREE. Measured: four tools in the backpack while
-- getBagItemCount read 4 for Egg x2 plus Iron Ore x2. Only stackable items cost
-- a slot, so the policy only has to be strict about those - and it can take a
-- better axe without ever thinking about room.
--
-- Everything is classified by the game's own tables rather than by name, so
-- there is no list here to keep in sync: Config.tool / Config.armour /
-- Config.food tag what they own, the four build materials are named, and
-- ANYTHING ELSE IS REFUSED. Spider Web, Bear Pelt, Chicken Feather, Grass and
-- the fire wands all fall through that last rule.
local MATERIALS = {
	Wood = true, Stone = true, ["Iron Ore"] = true, ["Iron Ingot"] = true,
}

local function taggedTool(name)
	local t = Config and Config.tool and Config.tool.byDisplayName
	return (t and t[name]) ~= nil
end
local function taggedArmour(name)
	local a = Config and Config.armour and Config.armour.byDisplayName
	return (a and a[name]) ~= nil
end

-- BAGS ARE WORLD PICKUPS, and the bag cap is this game's documented
-- bottleneck: 5 slots on bag_0, 15 on bag_1, 25 on bag_2. They live in
-- Assets.bag as Bag1..Bag4 and are handed out by chests and by the MrBeast
-- choice panel, so one can simply be lying on the ground.
--
-- They are NOT tagged as tool, food or armour in Config.item, so the strict
-- allowlist refused them - which would have walked the character straight past
-- the single biggest upgrade in the round. Named explicitly for that reason.
local function bagRowByName(name)
	for _, r in ipairs((Config and Config.bag and Config.bag.list) or {}) do
		if r.displayName == name then return r end
	end
	return nil
end

local function myBagLvl()
	local id = plr:GetAttribute("bagId") or "bag_0"
	local row = Config and Config.bag and Config.bag.byId and Config.bag.byId[id]
	return (type(row) == "table" and row.lvl) or 1
end

-- Only an UPGRADE. Walking back to a Small Bag would cut the bag from 15 to 5.
local function bagUpgrade(name)
	local row = bagRowByName(name)
	return row ~= nil and (row.lvl or 0) > myBagLvl()
end

-- neededStock walks every construction site and parses its BuildUI, so it is
-- far too expensive to run once per candidate drop in a 124-item folder.
local needCache, needAt = nil, 0
local function needNow()
	if os.clock() - needAt > 2 then
		needCache = CONFIG.onlyNeeded and neededStock() or nil
		needAt = os.clock()
	end
	return needCache
end

wantFilter = function(name)
	if dropSkipped(name) then return false end
	if bagUpgrade(name) then return true end
	if taggedTool(name) or taggedArmour(name) then return true end

	if foodRowForTool(name) then
		-- Food is picked up TO BE EATEN NOW, never stockpiled. One stack at a
		-- time and only while actually hungry: the bodyguard runs eatIfHungry
		-- every 0.35s, so a meal collected here is eaten before the next node.
		-- Standing reserves are what the player kept seeing - four Eggs, then a
		-- Cooked Egg and an Egg together, two of five slots parked on a hunger
		-- bar that was at 99.
		--
		-- eatBelowHunger is 70 of 100 and hunger ticks every 8s, so this still
		-- leaves a wide margin; huntFood is the rescue below it. That margin is
		-- the point - a blind sweep once filled the bag with wood while the meat
		-- it had just killed lay refused on the ground, and the character
		-- starved next to it.
		if #foodInBag() > 0 then return false end
		return (hunger()) < CONFIG.eatBelowHunger
	end

	if MATERIALS[name] then
		-- An ingot is never mined, it is carried from the furnace to the boat,
		-- so it is always wanted while anything is still open.
		if name == "Iron Ingot" then return true end
		local need = needNow()
		if not need then return true end
		return (need[name] or 0) - (bagContents()[name] or 0) > 0
	end

	return false
end

-- wantFilter decides what to PICK UP. It cannot clean the bag, and that is what
-- the player saw next: the Eggs stayed put after the filter was in, because
-- they had been collected before it existed and nothing ever takes anything
-- out again. The bag-full handler was the only route out, and with the bag
-- upgraded to 15 slots the bag is never full - so the trash simply rode along.
--
-- Deliberately NOT the same rule as wantFilter. "We already carry enough of
-- this" is a reason not to pick more up; it is emphatically not a reason to
-- throw away the stone we are carrying TO the furnace. Only things nothing
-- wants at all count as junk here.
local function carryJunk(name)
	if bagUpgrade(name) or taggedTool(name) or taggedArmour(name) then return false end
	if foodRowForTool(name) then
		-- Carried food is only worth a slot while it is about to be eaten;
		-- eatIfHungry runs every 0.35s, so below the threshold it is gone in a
		-- moment and above it there is no reason to be holding it.
		return (hunger()) >= CONFIG.eatBelowHunger
	end
	if MATERIALS[name] then
		if name == "Iron Ingot" then return false end
		local need = needNow()
		if not need then return false end
		return (need[name] or 0) <= 0
	end
	return true
end

-- Storage FIRST, because it keeps the item: food and spare material are worth
-- something later, and Storage takes a whole stack in one call. Only when there
-- is no Storage yet - which is most of day 1 - does anything hit the ground.
local function tidyBag()
	local junk = {}
	for _, t in ipairs(plr.Backpack:GetChildren()) do
		if t:IsA("Tool") and stackItem(t.Name) and carryJunk(t.Name) then
			junk[#junk + 1] = t.Name
		end
	end
	if #junk == 0 then return 0 end

	local keep = {}
	for name in pairs(bagContents()) do
		if not carryJunk(name) then keep[name] = true end
	end
	local moved = storeSurplus(keep)
	if moved > 0 then
		log("tidied %d away (%s)", moved, table.concat(junk, ", "))
		return moved
	end

	for _, name in ipairs(junk) do
		local freed = dropStack(name)
		if freed > 0 then
			log("tidied %d away (%s)", freed, name)
			return freed
		end
	end
	return 0
end

-- Verified path: EquipTool then Activate. Hunger went 19 -> 29 on a raw Crab,
-- exactly its hungerRegen of 10, and the tool was consumed.
-- Cooldowns. Without them the guard tried to eat every 0.35s: it grabbed the
-- hand, swapped food in, found nothing edible, swapped back - visible in game as
-- the axe flickering in and out and as swings that never landed.
local lastEat, lastHunt = 0, 0

local function eatIfHungry()
	local cur, max = hunger()
	if cur >= math.min(CONFIG.eatBelowHunger, max) then return false end
	if os.clock() - lastEat < 3 then return false end
	local food = foodInBag()
	if #food == 0 then return false end
	lastEat = os.clock()

	-- Spend the largest item that still fits in the deficit, so a 30-point
	-- cooked meat is not burned to top up the last five points.
	local deficit = max - cur
	local pick
	for _, f in ipairs(food) do
		local v = f.row.hungerRegen or 0
		if v <= deficit and (not pick or v > (pick.row.hungerRegen or 0)) then pick = f end
	end
	if not pick then
		for _, f in ipairs(food) do
			if not pick or (f.row.hungerRegen or 0) < (pick.row.hungerRegen or 0) then pick = f end
		end
	end
	if not pick then return false end

	local h = hum()
	if not h then return false end

	-- Count the HUNGER BAR, not the attempts. Counting calls reported "ate 72"
	-- while a single Crab sat in the bag the whole time and hunger fell from 61
	-- to 41 - the same lie the pickup counter told before it was fixed.
	--
	-- The 0.6s wait was also too short: eating plays an animation, and putting a
	-- weapon back in hand before it finished cancelled the meal every time.
	local before = cur
	withHand("eat", function()
		pcall(function() h:EquipTool(pick.tool) end)
		task.wait(0.35)
		local live_ = char() and char():FindFirstChild(pick.tool.Name)
		if live_ then pcall(function() live_:Activate() end) end
		-- Hold until the bar actually moves, up to 2.5s.
		local deadline = os.clock() + 2.5
		while os.clock() < deadline and (hunger()) <= before do task.wait(0.15) end
		-- Put a real tool back. Eating consumes the food, so re-equipping "what
		-- was held" often re-equipped a destroyed instance and left the hand on
		-- the next food item - which is how a tree ended up being hit with Meat.
		local w = bestWeapon()
		if w and w.tool and w.tool.Parent then pcall(function() h:EquipTool(w.tool) end) end
	end, 2)

	local after = hunger()
	if after <= before then return false end
	STATE.ate = (STATE.ate or 0) + 1
	STATE.note = string.format("ate, hunger %d -> %d", before, after)
	return true
end

--------------------------------------------------------------- MrBeast quests
-- The whole tool ladder hangs off this. You cannot craft a pickaxe without the
-- crafting table, the table needs stone, and stone needs a pickaxe - the only
-- way out of that circle is MrBeast, whose first quest asks for ONE wood and
-- pays a Wooden Pickaxe.
--
-- It is not a remote and not a drag. The game says it in plain words on screen -
-- "Drop wood toward MrBeast" - and the keybind strip says "[F]: Drop". So:
-- equip the item, stand next to him, and HOLD F for longer than
-- misc.confirmDropSec (1s). Measured: quest 1 -> 2, "Give Me Wood" became
-- "Give Me Stone", and a Wooden Pickaxe appeared in the backpack.
--
-- Everything else was a dead end: dropItem(tool), dropItem(slotIndex),
-- dropItem("wood"), ClientBackpack.fireDroppingTool(tool) and submitQuest all
-- returned cleanly and did nothing.
local MrbeastQuest = svc("MrbeastQuest")
local VIM = game:GetService("VirtualInputManager")

local function mrbeastNpc()
	local G = round()
	local t = G and G:FindFirstChild("Tiles")
	return t and t:FindFirstChild("Mrbeast", true) or nil
end

local function questWants()
	if not MrbeastQuest or not MrbeastQuest.getQuestRequirement then return nil end
	local idx = plr:GetAttribute("MrbeastQuestIndex") or 1
	local ok, req = pcall(MrbeastQuest.getQuestRequirement, idx)
	if not ok or type(req) ~= "table" then return nil end
	-- itemId is the internal id ("wood"); the Tool is named by displayName.
	local item = Config and Config.item and Config.item.byId and Config.item.byId[req.itemId]
	local display = (type(item) == "table" and item.displayName) or req.itemId
	return { itemId = req.itemId, count = req.count or 1, display = display, index = idx }
end

-- Hand one item over. Returns true when the quest index actually advanced.
local function giveToMrBeast()
	local want = questWants()
	if not want then return false, "no quest" end
	local npc = mrbeastNpc()
	local part = npc and npc:FindFirstChildWhichIsA("BasePart", true)
	if not part then return false, "npc not streamed in" end

	local tool
	for _, t in ipairs(plr.Backpack:GetChildren()) do
		if t.Name == want.display then tool = t break end
	end
	if not tool then return false, "no " .. want.display .. " to give" end

	local before = plr:GetAttribute("MrbeastQuestIndex")
	local ok = withHand("mrbeast", function()
		local h = hum()
		local root = hrp()
		if not h or not root then error("no character", 0) end
		local pinned = true
		local conn = RunService.Heartbeat:Connect(function()
			if pinned and root.Parent then
				root.CFrame = CFrame.new(part.Position + Vector3.new(0, 4, 6), part.Position)
			end
		end)
		task.wait(1.2)
		pcall(function() h:UnequipTools() end)
		task.wait(0.3)
		pcall(function() h:EquipTool(tool) end)
		task.wait(1.0)
		-- Hold F past confirmDropSec.
		pcall(function()
			VIM:SendKeyEvent(true, Enum.KeyCode.F, false, game)
			task.wait(1.8)
			VIM:SendKeyEvent(false, Enum.KeyCode.F, false, game)
		end)
		task.wait(2.5)
		pinned = false
		conn:Disconnect()
	end, 4)
	if not ok then return false, "busy" end

	local after = plr:GetAttribute("MrbeastQuestIndex")
	if after ~= before then
		STATE.quests = (STATE.quests or 0) + 1
		log("MrBeast quest %s -> %s (gave %s)", tostring(before), tostring(after), want.display)
		return true
	end
	return false, "gave " .. want.display .. " but quest did not advance"
end

------------------------------------------------------------------ boat parts
-- The boat needs materials AND four artifacts, shown as "Missing Parts" on the
-- right of the screen: Map, Radio, Compass, Plastic Bucket. Each sits in its own
-- `Prop Block NN` and each block is LOCKED - the model carries a "Collect"
-- ProximityPrompt with Enabled = false and a "0 / 6" label.
--
-- Config.mapLock spells out the key: unlockTrigger "击杀地块内任意怪物80%" =
-- kill 80% of the mobs inside that block (misc.blockUnlockKillRate 0.8). So the
-- routine is: clear the block, then take the artifact.
local PART_BLOCKS = { "Prop Block 01", "Prop Block 02", "Prop Block 03", "Prop Block 04" }

local function blockOf(name)
	local G = round()
	if not G then return nil end
	for _, d in ipairs(G:GetDescendants()) do
		if d.Name == name and d:IsA("Model") then return d end
	end
	return nil
end

local function mobsInBlock(blk)
	local G = round()
	if not G or not blk then return {} end
	local ok, cf, size = pcall(function()
		local c, s = blk:GetBoundingBox()
		return c, s
	end)
	if not ok or not cf then return {} end
	local out = {}
	for _, m in ipairs(G.Entities:GetChildren()) do
		local pp = m:FindFirstChild("HumanoidRootPart") or m.PrimaryPart
		local mh = m:FindFirstChildOfClass("Humanoid")
		if pp and mh and mh.Health > 0 and mh.Health < UNKILLABLE_HP and m.Name ~= "Shadow" then
			local rel = cf:PointToObjectSpace(pp.Position)
			if math.abs(rel.X) <= size.X / 2 and math.abs(rel.Z) <= size.Z / 2 then
				out[#out + 1] = { model = m, hum = mh, part = pp }
			end
		end
	end
	return out
end

local function collectPrompt(blk)
	if not blk then return nil end
	for _, d in ipairs(blk:GetDescendants()) do
		if d:IsA("ProximityPrompt") and d.ActionText == "Collect" then return d end
	end
	return nil
end

-- Returns true once the artifact has been taken.
local function clearPartBlock(name)
	local blk = blockOf(name)
	if not blk then log("%s: not in this map", name) return false end

	-- workspace.StreamingEnabled is TRUE here. The Prop Block model itself is
	-- always replicated, but the artifact inside it - and its Collect prompt -
	-- only stream in when the character is close. Searching from across the
	-- island found nothing at all and made four untouched blocks look finished.
	-- So: go there first, then wait for the contents to arrive.
	local anchorPart = blk:FindFirstChildWhichIsA("BasePart", true)
	if anchorPart then
		local root = hrp()
		if root then
			root.CFrame = CFrame.new(anchorPart.Position + Vector3.new(0, 18, 0))
			for _ = 1, 30 do
				task.wait(0.3)
				if collectPrompt(blk) then break end
			end
		end
	end

	local prompt = collectPrompt(blk)
	if prompt and not prompt.Parent then prompt = nil end
	if not prompt then log("%s: no Collect prompt after streaming in", name) return false end
	if prompt.Enabled then
		log("%s: already unlocked", name)
	else
		local w = bestWeapon()
		if not w then log("%s: no melee weapon", name) return false end
		local atk = math.max(1, w.row.atkDmg or 10)
		local h = hum()
		if h then pcall(function() h:EquipTool(w.tool) end) task.wait(0.2) end

		for _ = 1, 20 do
			if not live() or not alive() then return false end
			if prompt.Enabled then break end
			local list = mobsInBlock(blk)
			if #list == 0 then log("%s: no mobs left but still locked", name) break end
			local t = list[1]
			-- Strike from ABOVE. The server accepts a hit out to roughly twice
			-- the tool's range (~24 studs for a spear), so there is no reason to
			-- stand in the middle of a spider nest at 8 studs - which is exactly
			-- how the first attempt at this block got the character killed.
			-- Hovering at +14 keeps us inside that wall while melee mobs have
			-- nothing to path to.
			-- withPin itself adds (0,3,8), so this lands us about 15 studs from
			-- the mob and 13 above it - comfortably inside the ~24 stud wall.
			local hoverPos = t.part.Position + Vector3.new(0, 10, 0)
			withPin(hoverPos, CONFIG.settleTime, function()
				local n = math.clamp(math.ceil(t.hum.Health / atk) + 2, 1, CONFIG.maxEntries)
				Events.meleeHitRemote:FireServer(table.create(n, t.model), {})
				task.wait(0.5)
			end, true)
			STATE.blockKills = (STATE.blockKills or 0) + 1
			log("%s: cleared one, %d left, unlocked=%s", name, #list - 1, tostring(prompt.Enabled))
		end
	end

	if not prompt.Enabled then log("%s: still locked", name) return false end
	local anchor = prompt.Parent
	if not anchor:IsA("BasePart") then anchor = anchor:FindFirstChildWhichIsA("BasePart", true) end
	if not anchor then return false end
	local taken = false
	withPin(anchor.Position, CONFIG.settleTime, function()
		pcall(function() fireproximityprompt(prompt) end)
		task.wait(1.2)
		taken = (not prompt.Parent) or (not prompt.Enabled)
	end, true)
	log("%s: collect fired, taken=%s", name, tostring(taken))
	return taken
end

local function fetchBoatParts()
	local done = 0
	for _, name in ipairs(PART_BLOCKS) do
		if not live() or not alive() then break end
		if clearPartBlock(name) then done = done + 1 end
	end
	return done
end

----------------------------------------------------------------------- chests
-- 27 loot boxes sit in a fresh map and nothing in the normal farm loop touches
-- them. Verified: requestOpen on a "Loot Box House" from a pinned position
-- flipped isOpened to true and dropped a Bandage. They are the cheapest source
-- of tools and food in the round, and the tool ladder is what gates everything
-- else - a pickaxe cannot be crafted before the crafting table, and the table
-- needs stone, which needs a pickaxe.
local ChestService = svc("ChestService")

local function nextChest()
	local G = round()
	local folder = G and G:FindFirstChild("Chest")
	local root = hrp()
	if not folder or not root or not ChestService then return nil end
	local best, bd, bpart
	for _, c in ipairs(folder:GetChildren()) do
		local okO, opened = pcall(ChestService.client.isOpened, c)
		local okL, locked = pcall(ChestService.client.isLocked, c)
		if (not okO or not opened) and (not okL or not locked) then
			local p = c:FindFirstChildWhichIsA("BasePart", true)
			if p then
				local d = (p.Position - root.Position).Magnitude
				if not bd or d < bd then bd, best, bpart = d, c, p end
			end
		end
	end
	return best, bpart, bd
end

local function lootChest()
	local chest, part = nextChest()
	if not chest or not part then return false, "none left" end
	local picked = 0
	local ok = withHand("chest", function()
		local pinOk = withPin(part.Position, CONFIG.settleTime, function()
			pcall(ChestService.client.requestOpen, chest)
			-- Loot does not appear where the chest is: it pops out and FALLS,
			-- sometimes off a ledge. Sweeping once, immediately, at a tight
			-- radius left half of it on the ground - the player kept pointing
			-- at this. Wait for it to settle, sweep wide, then sweep again for
			-- whatever was still in the air the first time.
			task.wait(2)
			picked = collectDrops(part.Position, 60)
			task.wait(1)
			picked = picked + collectDrops(part.Position, 60)
		end, true)
		if not pinOk then error("pin failed", 0) end
	end, 0) -- never queue: the farm and the bodyguard both outrank a chest
	if not ok then return false, "busy" end
	STATE.chests = (STATE.chests or 0) + 1
	return true, picked
end

-------------------------------------------------------------------- game text
-- The game says what it wants in plain words - "Drop wood toward MrBeast",
-- "Materials Contributed!", "Insufficient Materials", "Not enough Wood". Those
-- lines are the cheapest feedback channel there is: they tell us whether an
-- action landed without a single extra remote call, and they name the next step
-- of the tutorial. Both the notify remotes and the visible labels are read.
local TEXT_GUIS = { Tutorial = true, ScreenNotifyGui = true, BannerNotify = true,
                    BuildNotify = true, Story = true, PickupNotify = true }

STATE.text = {}
local function pushText(s)
	if type(s) ~= "string" or s == "" then return end
	local t = STATE.text
	if t[#t] == s then return end          -- the same line repeats constantly
	t[#t + 1] = s
	while #t > 25 do table.remove(t, 1) end
	STATE.lastText = s
end

-- Tap every notification remote the game pushes to the client.
task.spawn(function()
	local seen = {}
	while live() do
		for _, d in ipairs(ReplicatedStorage:GetDescendants()) do
			if d:IsA("RemoteEvent") and not seen[d] then
				local p = d.Parent and d.Parent.Name or ""
				if p:find("Notify") or p:find("Banner") or p:find("Bubble") then
					seen[d] = true
					d.OnClientEvent:Connect(function(...)
						for i = 1, select("#", ...) do
							local v = select(i, ...)
							if type(v) == "string" then pushText(v) end
						end
					end)
				end
			end
		end
		task.wait(10)
	end
end)

-- ...and read whatever is actually on screen, which catches the tutorial line.
local function readGameText()
	local pg = plr:FindFirstChild("PlayerGui")
	if not pg then return {} end
	local out = {}
	for _, g in ipairs(pg:GetChildren()) do
		if g:IsA("ScreenGui") and g.Enabled and TEXT_GUIS[g.Name] then
			for _, d in ipairs(g:GetDescendants()) do
				if d:IsA("TextLabel") and d.Text ~= "" and d.Visible then
					local p, vis = d.Parent, true
					while p and p ~= g do
						if p:IsA("GuiObject") and not p.Visible then vis = false break end
						p = p.Parent
					end
					if vis then out[#out + 1] = d.Text end
				end
			end
		end
	end
	return out
end

task.spawn(function()
	while live() do
		if round() then
			for _, s in ipairs(readGameText()) do pushText(s) end
		end
		task.wait(1)
	end
end)

--------------------------------------------------------------------- campfire
-- The campfire is worth more than it looks. Cooking triples a meal - raw meat
-- is 10 hunger, cooked meat is 30 - it holds the night mobs off
-- (misc.campfireMobAtkDmgRate 0.5, campfireMobWalkSpeedRate 0.5) and its level
-- sets how far the safe wall reaches. One wood burns 35s at level 1.
local MakeFire = svc("MakeFire")

local function campfire()
	local G = round()
	local b = G and G:FindFirstChild("Buildings")
	if not b then return nil end
	for _, m in ipairs(b:GetChildren()) do
		if m.Name == "Campfire" or m:GetAttribute("CampfireMeshLevel") then return m end
	end
	return nil
end

local function campfireLit()
	local c = campfire()
	return c ~= nil and c:GetAttribute("onFire") == true
end

-- addWood takes no arguments, so the server resolves it from where we stand -
-- the position-gated pattern from .claude/docs/reverse-engineering.md. Pin to
-- the fire before firing it.
-- Burn wood to make room. A full bag refuses every pickup in silence, so a
-- character starving next to five slots of wood cannot pick up the meat it just
-- killed - measured, that is exactly how one died. The fire wants wood anyway,
-- so this costs nothing.
local function burnWoodForSpace(slots)
	if not MakeFire or not MakeFire.client then return 0 end
	local c = campfire()
	local part = c and c:FindFirstChildWhichIsA("BasePart", true)
	if not part then return 0 end
	local freed = 0
	withPin(part.Position, CONFIG.settleTime, function()
		for _ = 1, (slots or 2) do
			local before = bagCount()
			pcall(MakeFire.client.addWood)
			task.wait(0.6)
			if bagCount() >= before then break end
			freed = freed + (before - bagCount())
		end
	end)
	return freed
end

local function feedFire()
	if not MakeFire or not MakeFire.client then return false, "no MakeFire" end
	local c = campfire()
	if not c then return false, "no campfire built" end
	if c:GetAttribute("onFire") == true then return false, "already lit" end
	if bagCount() == 0 then return false, "nothing in bag" end

	local part = c:FindFirstChildWhichIsA("BasePart", true)
	if not part then return false, "no part" end
	local ok = withPin(part.Position, CONFIG.settleTime, function()
		MakeFire.client.addWood()
	end)
	task.wait(0.5)
	return (c:GetAttribute("onFire") == true), ok and "fired" or "pin failed"
end

-- Mobs that are food on the hoof. Chickens drop meat and eggs, crabs drop crab.
local FOOD_MOBS = { Chicken = true, Crab = true }

-- Standing still with an empty bag and hunger 19 is a slow death, so when there
-- is nothing to eat the guard goes and gets some. This MOVES the character,
-- which is why it only runs while actually hungry and out of food.
local function huntFood()
	local G = round()
	local root = hrp()
	if not G or not root or not alive() then return false end
	-- Pins the body on Heartbeat itself rather than through withPin, so it needs
	-- its own copy of the halt check or it will drag the character out of the
	-- escape cutscene chasing a chicken.
	if cutscene() then return false end
	local ents = G:FindFirstChild("Entities")
	if not ents then return false end

	local best, bd, bh
	for _, m in ipairs(ents:GetChildren()) do
		if FOOD_MOBS[m.Name] then
			local mh = m:FindFirstChildOfClass("Humanoid")
			local pp = m:FindFirstChild("HumanoidRootPart") or m.PrimaryPart
			if mh and pp and mh.Health > 0 then
				local d = (pp.Position - root.Position).Magnitude
				if not bd or d < bd then bd, best, bh = d, m, mh end
			end
		end
	end
	if not best then return false end

	local w = bestWeapon()
	if not w then return false end
	local h = hum()
	local got = withHand("hunt", function()
		if h then pcall(function() h:EquipTool(w.tool) end) task.wait(0.2) end
	end)
	if not got then return false end
	local atk = math.max(1, w.row.atkDmg or 10)

	STATE.note = "hungry - hunting " .. best.Name
	local pinned = true
	local conn = RunService.Heartbeat:Connect(function()
		if pinned and root.Parent then
			local pp = best.Parent and (best:FindFirstChild("HumanoidRootPart") or best.PrimaryPart)
			if pp then root.CFrame = CFrame.new(pp.Position + Vector3.new(0, 3, 7), pp.Position) end
		end
	end)
	local ok = pcall(function()
		task.wait(CONFIG.settleTime)
		if not alive() then error("died hunting", 0) end
		local n = math.clamp(math.ceil(bh.Health / atk) + 1, 1, CONFIG.maxEntries)
		Events.meleeHitRemote:FireServer(table.create(n, best), {})
		task.wait(0.8)
	end)
	pinned = false
	conn:Disconnect()
	if not ok then return false end
	-- Food ONLY. This is a rescue trip, and a bag slot spent on wood here is a
	-- meal left on the ground.
	collectDrops(root.Position, 45, function(name) return foodRowForTool(name) ~= nil end)
	return true
end

local function hostilesNear(radius)
	local G = round()
	local root = hrp()
	if not G or not root then return {} end
	local ents = G:FindFirstChild("Entities")
	if not ents then return {} end
	local out = {}
	for _, m in ipairs(ents:GetChildren()) do
		local mh = m:FindFirstChildOfClass("Humanoid")
		local pp = m:FindFirstChild("HumanoidRootPart") or m.PrimaryPart
		if mh and pp and mh.Health > 0 and mh.Health < UNKILLABLE_HP and m.Name ~= "Shadow" then
			local d = (pp.Position - root.Position).Magnitude
			if d <= radius then out[#out+1] = { model = m, hum = mh, dist = d } end
		end
	end
	table.sort(out, function(a, b) return a.dist < b.dist end)
	return out
end

-- One call per mob, sized to its health. Duplicates multiply on mobs exactly as
-- they do on resources - measured, a Chicken took 10 from `{m}` and 30 from
-- `{m,m,m}` - so anything that walks into reach dies before it can swing.
local function defend()
	if not alive() then return 0 end
	local root = hrp()
	if not root then return 0 end
	local w = bestWeapon()
	if not w then return 0 end
	local atk   = math.max(1, w.row.atkDmg or 10)
	local reach = (w.row.range or 11) * 2 - 2

	-- Only look as far as we can actually HIT. Scanning 60 studs and equipping
	-- on anything found there made the character swap between axe and spear
	-- several times a second for crabs it could never reach - the player saw the
	-- tool flickering and the body jumping back and forth. The server wall is
	-- about twice the tool's range, so that is the only radius worth reacting to.
	local near = hostilesNear(reach)
	if #near == 0 then return 0 end

	local _, held = equippedTool()
	if not held or held.id ~= w.row.id then
		-- Do not steal the hand mid-harvest; the mob will still be there in
		-- 0.35s and a swing lost to a swapped tool costs more.
		local ok = withHand("defend", function()
			local h = hum()
			if h then pcall(function() h:EquipTool(w.tool) end) task.wait(0.2) end
		end)
		if not ok then return 0 end
	end

	local killed = 0
	for _, e in ipairs(near) do
		if not live() or not alive() then break end
		local pp = e.model.Parent and (e.model:FindFirstChild("HumanoidRootPart") or e.model.PrimaryPart)
		if pp and (pp.Position - root.Position).Magnitude <= reach then
			local n = math.clamp(math.ceil(e.hum.Health / atk) + 1, 1, CONFIG.maxEntries)
			Events.meleeHitRemote:FireServer(table.create(n, e.model), {})
			killed = killed + 1
		end
	end
	return killed
end

------------------------------------------------------------- node selection
-- Which resource ids we still want, in priority order. Wood first: the campfire
-- and the workbench both gate on it and both are cheap.
-- `stock` is the Tool name the material shows up as in the backpack, which is
-- how the harvester works out which resource it is short of.
local WANT = {
	{ key = "farmWood",  stock = "Wood",     ids = { "Tree", "Coconut Tree", "Mushtree", "Elf Tree" } },
	{ key = "farmStone", stock = "Stone",    ids = { "Stone" } },
	{ key = "farmIron",  stock = "Iron Ore", ids = { "Iron Stone" } },
}

-- "Can we harvest it" means "do we OWN a tool that fits", not "is one in hand" -
-- fellNode equips before it swings.
local function canHarvest(node, owned)
	local id = node:GetAttribute("resourceId")
	if not id then return false end
	local row = resourceRow(id)
	if not row then return false end
	if row.requireToolType == "any" then return true end
	owned = owned or ownedTools()
	return owned[row.requireToolType] ~= nil
end

local function nextNode()
	local G = round()
	if not G then return nil end
	local static = G:FindFirstChild("Static")
	local root = hrp()
	if not static or not root then return nil end

	local owned = ownedTools()

	-- Mine what we are SHORT of, not what is nearest. Trees are everywhere, so
	-- a fixed wood-first order felled 17 of them in a row while a Nest sat at
	-- "6 / 6 wood, 0 / 3 stone" and the bag stayed jammed. Bag items are Tools
	-- named after the material, so counting them is free.
	local have = bagContents()
	-- Only chase what a construction site is still short of. Once every wood row
	-- is full, another tree is a wasted bag slot - the player pointed at exactly
	-- this: "die Items hier brauchst du halt nicht".
	local need = CONFIG.onlyNeeded and neededStock() or nil

	-- What is still OUTSTANDING: what the sites want, minus what is already in
	-- the bag on its way there. A material we are carrying enough of drops out
	-- entirely - carrying an eleventh wood towards a 10/10 row is a bag slot
	-- spent on nothing, and the bag is five slots.
	local function outstanding(g)
		if not need then return 1 end
		return (need[g.stock] or 0) - (have[g.stock] or 0)
	end

	local order = {}
	for _, g in ipairs(WANT) do
		if outstanding(g) > 0 then order[#order + 1] = g end
	end
	if #order == 0 then for i, g in ipairs(WANT) do order[i] = g end end
	-- Biggest shortfall first. Sorting by what was in the BAG meant wood and
	-- stone both read 0 straight after a delivery, WANT's own order broke the
	-- tie, and trees - which stand everywhere, while stone is sparse - won every
	-- time. Measured over one round: 85 trees to 11 stone, with the furnace
	-- still at 0/10 stone.
	table.sort(order, function(a, b)
		local ra, rb = outstanding(a), outstanding(b)
		if ra ~= rb then return ra > rb end
		return (have[a.stock] or 0) < (have[b.stock] or 0)
	end)

	-- If the wanted material is unreachable - needing Stone while owning only an
	-- axe, which stalled the farm completely with "no reachable node" - fall
	-- back to everything we CAN harvest rather than standing still.
	local passes = { order }
	if need then passes[2] = WANT end

	for _, groups in ipairs(passes) do
	for _, group in ipairs(groups) do
		if CONFIG[group.key] then
			local want = {}
			for _, id in ipairs(group.ids) do want[id] = true end
			local best, bd
			for _, m in ipairs(static:GetChildren()) do
				local id = m:GetAttribute("resourceId")
				local hp = m:GetAttribute("hp")
				if id and want[id] and hp and hp > 0 and canHarvest(m, owned) then
					local p = nodePart(m)
					if p then
						local d = (p.Position - root.Position).Magnitude
						if not bd or d < bd then bd, best = d, m end
					end
				end
			end
			if best then return best end
		end
	end
	end
	return nil
end

------------------------------------------------------------------ crafting
local craftIdByName
local function craftId(englishId)
	if not craftIdByName and Config and Config.canCraft then
		craftIdByName = Config.canCraft.byId or {}
	end
	local row = craftIdByName and craftIdByName[englishId]
	return row and (row.CN or row.id) or englishId
end

local function craft(englishId)
	if not CraftItems then return false end
	return pcall(CraftItems.client.craft, craftId(englishId))
end

local function build(id)
	if not BuildBuilding then return false end
	return pcall(BuildBuilding.client.build, id)
end

-- `build(id)` does NOT place a construction site - measured, calling it with
-- storage, furnace and a deliberately nonsense id changed nothing at all. What
-- it does is DELIVER the bag's materials into a matching `<Name>_Construct`
-- that the game has already placed through tutorial progression. So iterate
-- what actually exists in the world, in BUILD_ORDER priority.
--
-- Defined HERE, above every loop that uses it. It first lived next to the
-- autoBuild loop, which sits after the farm loop, and the farm loop's call to
-- it failed as a quiet "attempt to call a nil value" in the status line. Third
-- time this file hit that trap.
-- What is still WANTED, read off the construction sites themselves.
--
-- Each site's BuildUI lists one row per material in recipe order, and the rows
-- line up with the non-zero requirements of `Config.recipe.byId[<id>]`:
--   Nest      [6 / 6 | 0 / 3]          <- wood 6, stone 3
--   Furnace   [10 / 10 | 0 / 10]       <- wood 10, stone 10
--   Boat      [20 / 20 | 8 / 20 | 0/10]<- wood 20, stone 20, ironIngot 10
-- so a row that is not full names a material still needed. Once every wood row
-- is complete, carrying wood is pure bag waste - and the bag is five slots.
local RECIPE_FIELDS = {
	{ field = "require_wood",      stock = "Wood" },
	{ field = "require_stone",     stock = "Stone" },
	{ field = "require_ironIngot", stock = "Iron Ore" },
}

-- Per-construct demand, so a delivery is only attempted when we are actually
-- carrying something that site wants. Firing `build` blindly prints
-- "Insufficient Materials" and "Not enough Wood" in huge red letters across the
-- player's screen, several times a second - the loop was working as designed and
-- still made the game unusable to look at.
local constructNeeds = {}

function neededStock()
	local G = round()
	local b = G and G:FindFirstChild("Buildings")
	if not b or not Config or not Config.recipe then return nil end
	local need, any = {}, false
	constructNeeds = {}
	-- The construct is named `Tent_Construct` while the recipe id is `tent`, and
	-- the crafting table is `制作台_Construct` against a recipe id of
	-- `制作台配方`. Matching the raw prefix found nothing at all and the whole
	-- demand scan silently returned nil.
	-- IRON ORE IS USELESS WITHOUT A BUILT FURNACE. Nothing in the game consumes
	-- ore directly - verified against every recipe, the only consumer is
	-- misc.furnaceMatter1Id - so until a Furnace actually stands, ore mined for
	-- the boat's ten ingots is dead weight in a five-slot bag. The player caught
	-- this: "wofuer braucht er das iron gerade, er macht nichts damit". Measured
	-- at that moment: Furnace_Construct present, no Furnace, and two of five
	-- slots holding ore while the furnace site itself still wanted 9 stone and
	-- 10 wood.
	--
	-- `Furnace` is the finished building; `Furnace_Construct` is the site.
	local hasFurnace = b:FindFirstChild("Furnace") ~= nil

	local byId = Config.recipe.byId or {}
	local function recipeFor(base)
		if not base then return nil end
		return byId[base] or byId[base:lower()] or byId[base .. "配方"]
	end

	for _, m in ipairs(b:GetChildren()) do
		local base = m.Name:match("^(.-)_Construct$")
		local recipe = recipeFor(base)
		local reqFrame = m:FindFirstChild("requires", true)
		if type(recipe) == "table" and reqFrame then
			local rows = {}
			for _, f in ipairs(reqFrame:GetChildren()) do
				local c = f:FindFirstChild("count", true)
				if c then rows[#rows + 1] = c.Text end
			end
			local i = 0
			for _, spec in ipairs(RECIPE_FIELDS) do
				if (recipe[spec.field] or 0) > 0 then
					i = i + 1
					local txt = rows[i]
					local have, want = tostring(txt):match("(%d+)%s*/%s*(%d+)")
					-- `i` must keep counting for EVERY non-zero field even when
					-- the demand is skipped: it is the row index into the site's
					-- BuildUI, and letting it slip would silently read the wrong
					-- material's numbers for everything after it.
					local usable = (spec.field ~= "require_ironIngot") or hasFurnace
					if have and want and tonumber(have) < tonumber(want) and usable then
						-- HOW MANY are missing, not just that something is. A
						-- boolean made every open material look equally urgent,
						-- and the harvester then broke the tie on what was
						-- already in the bag - which is zero for both right
						-- after a delivery, so wood (first in WANT, and trees
						-- are everywhere) won every single time. The log:
						-- 85 trees felled against 11 stone, while every wood row
						-- on the island was already full and the furnace sat at
						-- 0/10 stone.
						local short = tonumber(want) - tonumber(have)
						need[spec.stock] = (need[spec.stock] or 0) + short
						any = true
						local key = base:lower()
						constructNeeds[key] = constructNeeds[key] or {}
						constructNeeds[key][spec.stock] = short
					end
				end
			end
		end
	end
	-- An ironIngot is not mined, it is SMELTED: furnace takes ironOre plus wood
	-- (misc.furnaceMatter1Id / furnaceMatter2Id) and 10s per ingot. So a boat
	-- asking for 10 ingots really asks for iron ore AND firewood, and filtering
	-- wood out at that moment stalls the escape completely.
	--
	-- But fuel is a SMALL, capped need. Adding it as an open-ended one is what
	-- kept wood at the top of the priority list for the whole round: the boat
	-- always wants ingots, so wood was always "needed", so the axe never stopped.
	-- One wood per ingot, ten ingots, and only what we are not already carrying.
	if need["Iron Ore"] then
		local fuel = math.max(0, 10 - (bagContents()["Wood"] or 0))
		if fuel > 0 then need["Wood"] = math.max(need["Wood"] or 0, fuel) end
	end
	if not any then return nil end
	return need
end

local function pendingConstructs()
	local G = round()
	local b = G and G:FindFirstChild("Buildings")
	if not b then return {} end
	local out = {}
	for _, m in ipairs(b:GetChildren()) do
		local base = m.Name:match("^(.-)_Construct$")
		if base then out[base:lower()] = m end
	end
	return out
end

-- Furnace: ironOre + wood -> ironIngot, 10s, and the boat needs ten ingots.
-- Its service module hangs on require (see svc above), so when the module is
-- unavailable we fall back to its own remotes.
--
-- UNVERIFIED: the payloads below are inferred from the client functions'
-- constants - addBoth carried "both" and addMatter1 carried "matter1" next to
-- "FireServer", and collectResult carried only "FireServer". That is a strong
-- reading, not a measurement. Confirm against an ingot actually appearing
-- before trusting it.
local furnaceFolder = E:FindFirstChild("Furnace")

local function furnaceBuilding()
	local G = round()
	local b = G and G:FindFirstChild("Buildings")
	if not b then return nil end
	return b:FindFirstChild("Furnace")
end

-- addBoth / collectResult take no arguments, so the server resolves them from
-- where we stand. Pin to the furnace first, exactly like addWood.
local function furnaceTick()
	local f = furnaceBuilding()
	local part = f and f:FindFirstChildWhichIsA("BasePart", true)
	if not part then return "no furnace" end

	local how, added = "remote", 0
	withPin(part.Position, CONFIG.settleTime, function()
		-- The Furnace service module hangs on require (see svc), so drive its
		-- own remotes instead.
		if not furnaceFolder then how = "missing" return end
		local collect = furnaceFolder:FindFirstChild("collectResultRemote")
		local addTask = furnaceFolder:FindFirstChild("addTaskRemote")
		-- COLLECT EVERYTHING THAT IS READY, not one per visit. The furnace hands
		-- finished ingots out onto the GROUND, and firing collectResult once per
		-- eight-second tick left them piling up there - the player counted a
		-- heap of them lying in front of the furnace while the boat still wanted
		-- ingots. Fire it until it stops producing, then sweep what landed.
		if collect then
			for _ = 1, 12 do
				if not live() then break end
				pcall(function() collect:FireServer() end)
				task.wait(0.2)
			end
		end
		task.wait(0.3)
		-- The output lands as drops at our feet; pick the ingots up before we
		-- walk away from them.
		if CONFIG.autoCollect then
			collectDrops(part.Position, 45, function(nm) return nm == "Iron Ingot" end)
		end
		if not addTask then how = "no addTask" return end

		-- ONE CALL MOVES ONE UNIT. Captured with the spy while the furnace's own
		-- addMatter1Btn was fired: `addTaskRemote("matter1")` - a single string,
		-- no count argument anywhere. The old code fired it once per eight-second
		-- tick, so a whole visit deposited at most one ore and one wood, and the
		-- ten ingots the boat wants took forever while the bag stayed clogged
		-- with ore. Fire it until the material is actually out of the bag: one
		-- trip, the entire load.
		--
		-- Counting the BAG, not the calls - a refused add returns just as
		-- cleanly as an accepted one, the same lie the pickup counter told.
		local function drain(arg, stock, budget)
			local moved, stall = 0, 0
			for _ = 1, 30 do
				if not live() or moved >= budget then break end
				local have = bagContents()[stock] or 0
				if have <= 0 then break end
				pcall(function() addTask:FireServer(arg) end)
				task.wait(0.25)
				if (bagContents()[stock] or 0) >= have then
					-- Refused: the furnace is full or busy. Two in a row is
					-- enough to stop rather than spam a remote that says no.
					stall = stall + 1
					if stall >= 2 then break end
				else
					moved = moved + 1
					stall = 0
				end
			end
			return moved
		end

		-- Ore has exactly one consumer, so all of it can go in.
		local ore = drain("matter1", "Iron Ore", 30)
		-- Wood does NOT: the boat, the tent and every other site want it too, so
		-- only enough fuel to smelt what just went in (one wood per ingot,
		-- misc.furnaceMatter2Id). Dumping the whole wood stack here would starve
		-- the construction sites the farm is otherwise feeding.
		local fuel = ore > 0 and drain("matter2", "Wood", ore) or 0
		added = ore + fuel
		if ore > 0 or fuel > 0 then
			log("furnace: +%d ore, +%d wood", ore, fuel)
		end
	end)
	return how .. (added > 0 and (" +" .. added) or "")
end

-- Damage first, exactly like every other script here: the tool ladder raises
-- harvest throughput directly, and everything else waits on it.
local TOOL_LADDER = { "woodAxe", "woodPickaxe", "stoneAxe", "stonePickaxe", "ironAxe", "ironPickaxe" }
-- Priority order for delivering materials. Campfire first (safety, cooking and
-- the wall), then the crafting table (tools), storage (the bag cap of 5 is the
-- real bottleneck), the furnace (ingots for the boat), then the comfort
-- buildings, then the boat itself.
--
-- Anything not on this list is still delivered to rather than leaving the bag
-- deadlocked - a full bag stops the farm completely, and the first version had
-- exactly that: 12 trees felled, then "bag full 5/5" forever because the only
-- open construction site was a Nest and `nest` was missing from this list.
local BUILD_ORDER = { "campfire", "制作台", "storage", "furnace", "nest", "tent", "boat" }

--------------------------------------------------------------------- the loop
local function loop(sec, key, fn)
	task.spawn(function()
		while live() do
			-- Nothing runs during the escape cutscene or the result screen.
			-- Gating withPin alone was not enough: the farm loop's relocate
			-- branch writes root.CFrame directly, and that is the teleport that
			-- was breaking the escape.
			local halted, which = cutscene()
			if halted then
				note("round over (" .. tostring(which) .. ") - holding still")
			elseif CONFIG.auto and (key == nil or CONFIG[key]) then
				local ok, err = pcall(fn)
				if not ok then note("err: " .. tostring(err)) end
			end
			task.wait(sec)
		end
	end)
end

-- Mirror the round state into STATE; this is a free oracle, no remote involved.
-- Deliberately NOT gated on CONFIG.auto: the panel has to show the day, the
-- phase and the bag before anyone turns the master switch on, and gating this
-- left the whole header reading "day 0  -" while the round was clearly running.
task.spawn(function()
	while live() do
		local G = round()
		if G then
			STATE.day    = G.Day and G.Day.Value or 0
			STATE.phase  = G.Phase and G.Phase.Value or "-"
			STATE.remain = math.floor(G.PhaseRemainTime and G.PhaseRemainTime.Value or 0)
			STATE.bag    = bagCount()
			-- Remember the last height at which we were actually standing on
			-- something, so the hover has a floor to measure from and does not
			-- climb a little further every tick.
			local h, root = hum(), hrp()
			if h and root and h.FloorMaterial ~= Enum.Material.Air then
				STATE.groundY = root.Position.Y
			end
		else
			STATE.phase = inLobby() and "lobby" or "-"
		end
		task.wait(0.5)
	end
end)

-- Hover out of reach. Melee mobs have to path to you and their reach is small,
-- so parking a few studs up puts the character where nothing can connect. This
-- is only a POSITION change - the same CFrame writing the farm already does to
-- reach a node - which makes it far less conspicuous than rewriting health, and
-- it costs nothing when the farm needs the body back: the pin simply wins,
-- because it runs on the same Heartbeat and is applied after this.
-- THE SHADOW. It carries 1,000,000 HP, so there is nothing to fight - the
-- config says so outright: shadowTargetHp 30 (it comes for you when you are
-- hurt), shadowLeaveTime 10, and it spawns on even days after a 20s delay.
-- Hovering is not enough because it can close distance on its own; the answer
-- is to leave, far, and wait it out. Everything else is paused while it is
-- around, since nothing useful can happen anyway.
task.spawn(function()
	while live() do
		task.wait(0.4)
		if not (CONFIG.evadeShadow and alive() and round()) then continue end
		local G = round()
		local ents = G:FindFirstChild("Entities")
		local root = hrp()
		if not ents or not root then continue end

		local shadow, sp
		for _, m in ipairs(ents:GetChildren()) do
			if m.Name == "Shadow" then
				local mh = m:FindFirstChildOfClass("Humanoid")
				local pp = m:FindFirstChild("HumanoidRootPart") or m.PrimaryPart
				if mh and pp and mh.Health > 0 then shadow, sp = m, pp break end
			end
		end
		if not (shadow and sp) then continue end

		local dist = (sp.Position - root.Position).Magnitude
		if dist > CONFIG.shadowFleeRadius then continue end

		-- Only actually run when it can hurt us. misc.shadowTargetHp is 30: it
		-- comes for players who are already hurt. A blanket 220-stud panic
		-- radius made this fire 65 times in five minutes - flee, drift back,
		-- flee again - and that thrash cost more progress than the Shadow ever
		-- did. Healthy and not on top of us: carry on working.
		local h = hum()
		local hurt = h and h.Health <= math.max(CONFIG.shadowFleeHp, 0)
		if not hurt and dist > CONFIG.shadowPanicRadius then continue end
		if os.clock() - (STATE.lastShadowFlee or 0) < 8 then continue end
		STATE.lastShadowFlee = os.clock()

		-- Take the hand so the farm cannot warp us back into its path.
		withHand("shadow", function()
			note("SHADOW nearby - fleeing")
			local t0 = os.clock()
			while os.clock() - t0 < 20 and live() and alive() do
				local r = hrp()
				local p = shadow.Parent and (shadow:FindFirstChild("HumanoidRootPart") or shadow.PrimaryPart)
				if not r then break end
				if not p then break end
				local d = (p.Position - r.Position).Magnitude
				if d > CONFIG.shadowFleeRadius * 2 then break end
				local away = (r.Position - p.Position)
				if away.Magnitude < 1 then away = Vector3.new(1, 0, 0) end
				local dest = r.Position + away.Unit * 250
				r.CFrame = CFrame.new(Vector3.new(dest.X, STATE.groundY + 90, dest.Z))
				r.AssemblyLinearVelocity = Vector3.zero
				task.wait(0.3)
			end
			log("shadow evaded")
		end, 1)
	end
end)

-- NIGHT = GET OFF THE GROUND.
--
-- The health guard below keeps the local bar full but does NOT keep you alive:
-- the server runs its own damage and death, and a character can be killed with
-- a full green bar on screen. Measured the hard way. So the only real defence
-- is not being reachable, and standing still through the night in the open -
-- which is what nightSafety used to do - is the worst possible version of that.
--
-- Melee mobs have to path to the body. Parked well above the ground nothing
-- connects, and it costs nothing: the farm's own pin still wins whenever it
-- takes the hand, because it is applied later in the same Heartbeat.
task.spawn(function()
	while live() do
		RunService.Heartbeat:Wait()
		if CONFIG.hoverAtNight and alive() and round() and hand.owner == nil then
			local danger = STATE.phase == "night" or #hostilesNear(30) > 0
			if danger then
				local root = hrp()
				if root then
					local base = STATE.groundY
					if base == 0 then base = root.Position.Y end
					local wantY = base + CONFIG.hoverHeight
					if root.Position.Y < wantY - 1 then
						root.CFrame = CFrame.new(root.Position.X, wantY, root.Position.Z)
					end
					root.AssemblyLinearVelocity = Vector3.zero
				end
			end
		end
	end
end)

-- Damage immunity. Measured: the player's Humanoid.Health is CLIENT-authored
-- here - writing 50 stuck for 2.5s, writing MaxHealth back stuck too, and the
-- server never corrected either. So topping the bar back up is enough.
--
-- This is louder than anything else in this script. An auto-farm looks like
-- somebody playing fast; a character that never takes damage is the single most
-- obvious pattern there is if the developers ever add a server-side health
-- check. Off by default, and it is a deliberate choice, not a default.
--
-- It also does NOT feed you: hunger still falls, and with this on a starving
-- character simply stops showing the symptom instead of dying. Leave the eating
-- loop on.
-- WARNING, measured: this does NOT make you immortal. Writing Health is not
-- corrected by the server, so the on-screen bar stays full - but the server
-- keeps its own damage tally and its own death trigger, and it killed a
-- character whose local bar was still green. Treat this as cosmetic smoothing
-- of the bar, never as protection; the hover above is the defence that works.
--
-- Polling every 0.1s was not enough: a single hard hit crosses the whole bar
-- inside one tick, Health lands on 0, and a restore after the fact is too late
-- because the death has already fired. Hooking HealthChanged puts the restore
-- in the same frame as the damage, and the Heartbeat pass below is only a
-- backstop for anything that slips through.
local healthConn
local function armHealthGuard(h)
	if healthConn then healthConn:Disconnect() healthConn = nil end
	if not h then return end
	healthConn = h.HealthChanged:Connect(function(value)
		if CONFIG.noDamage and value < h.MaxHealth then
			pcall(function() h.Health = h.MaxHealth end)
		end
	end)
end

plr.CharacterAdded:Connect(function(c)
	local h = c:WaitForChild("Humanoid", 10)
	if h then armHealthGuard(h) end
end)
if plr.Character then armHealthGuard(plr.Character:FindFirstChildOfClass("Humanoid")) end

task.spawn(function()
	while live() do
		RunService.Heartbeat:Wait()
		if CONFIG.noDamage then
			local h = hum()
			if h and h.Health < h.MaxHealth then
				-- No `> 0` guard: restoring from exactly 0 is the case that
				-- matters most, and it still works while the body exists.
				pcall(function() h.Health = h.MaxHealth end)
			end
		end
	end
end)

-- Bodyguard. Deliberately NOT gated on CONFIG.auto: the whole point is that the
-- character survives while the master switch is OFF and someone is measuring,
-- which is when it kept dying.
task.spawn(function()
	while live() do
		if alive() and round() and not cutscene() then
			local ok, err = pcall(function()
				if CONFIG.autoDefend then
					local n = defend()
					if n > 0 then STATE.guarded = (STATE.guarded or 0) + n end
				end
				-- Eating is the half that actually keeps you alive while idle.
				if CONFIG.autoEat then
					local cur = (hunger())
					-- An empty larder is the common case: the guard kills a
					-- chicken and the meat lies on the floor until someone
					-- picks it up. Sweep before deciding we cannot eat.
					-- Only go looking when genuinely low, and not more than once
					-- every 15s: hunting pins and moves the character, which is
					-- the most disruptive thing this script does.
					if cur < CONFIG.eatBelowHunger and #foodInBag() == 0
					   and os.clock() - lastHunt > 15 then
						lastHunt = os.clock()
						-- Make room FIRST. Hunting into a full bag kills you
						-- next to the meal you just killed.
						if bagFull() then
							STATE.note = "starving, bag full - burning wood"
							burnWoodForSpace(3)
						end
						collectDrops(nil, 45, function(nm) return foodRowForTool(nm) ~= nil end)
						if CONFIG.autoHunt and #foodInBag() == 0 and not bagFull() then huntFood() end
					end
					eatIfHungry()
				end
			end)
			if not ok then STATE.note = "guard: " .. tostring(err) end
		end
		task.wait(0.35)
	end
end)

-- The farm loop.
loop(0.25, nil, function()
	if not round() then note("waiting for a round"); return end
	if not alive() then note("dead - waiting"); return end
	-- KEEP WORKING AT NIGHT. Night is 1.5 of every 4.5 minutes, so standing
	-- still through it threw away a third of the round - the log came back 57
	-- lines of "night - holding" out of 60. It is safe to carry on now: the
	-- hover keeps melee mobs from reaching us and the Shadow is fled from
	-- outright. `nightSafety` still exists for anyone who wants the old
	-- behaviour, it is just no longer the default.
	if CONFIG.nightSafety and STATE.phase == "night" then
		note("night - holding")
		return
	end
	-- Felling into a full bag throws the drops away: the node is consumed and
	-- the server refuses the pickup. Let the craft and build loops drain it
	-- first.
	if bagFull() then
		-- A full bag stops everything, and the bag is only five slots. If no
		-- construction site wants what we are carrying, burn the wood: the fire
		-- wants it anyway and the slots are worth more than the log. Without
		-- this the farm sat on "bag full 5/5" for whole days because the only
		-- open site was a Nest waiting on stone.
		-- A full bag stops everything. Put whatever the build plan no longer
		-- wants into Storage (it is kept, not thrown away), and only burn wood
		-- if there is nowhere to store it.
		local keep = neededStock() or {}
		local moved = storeSurplus(keep)
		if moved > 0 then
			note(string.format("bag was full - stored %d away", moved))
		else
			local freed = burnWoodForSpace(2)
			if freed > 0 then
				note("bag full - burned " .. freed .. " wood for space")
			else
				-- Last resort: throw something the plan does not want on the
				-- ground. It stays there and can be collected again later.
				--
				-- WORST FIRST. The old version took whatever came out of
				-- GetChildren, so it was as likely to throw away the Stone the
				-- furnace was waiting on as the Spider Web sitting next to it.
				-- Junk, then a surplus second food stack, then a material we
				-- are carrying more of than anything still wants.
				local carried = bagContents()
				local foodStacks = #foodInBag()
				local function rank(name)
					if not MATERIALS[name] and not foodRowForTool(name) then return 0 end
					if foodRowForTool(name) then return foodStacks > 1 and 1 or 3 end
					if (keep[name] or 0) - (carried[name] or 0) <= 0 then return 2 end
					return 4
				end

				local cands = {}
				for _, t in ipairs(plr.Backpack:GetChildren()) do
					if t:IsA("Tool") and stackItem(t.Name) then
						cands[#cands + 1] = { name = t.Name, rank = rank(t.Name) }
					end
				end
				table.sort(cands, function(a, b) return a.rank < b.rank end)

				local dumped = 0
				for _, c in ipairs(cands) do
					-- rank 4 is "the build plan is still short of this" - never
					-- throw that away, it is the whole reason we are carrying it.
					if c.rank >= 4 then break end
					dumped = dropStack(c.name)
					if dumped > 0 then break end
				end
				if dumped > 0 then
					note(string.format("bag full - dropped %d to keep going", dumped))
				else
					note(string.format("bag full %d/%d and nothing to unload",
						bagCount(), bagCap()))
				end
			end
		end
		task.wait(1)
		return
	end
	local node = nextNode()
	if not node then
		-- StreamingEnabled means Workspace.Game.Static only holds what is loaded
		-- AROUND US. Hovering out of a fight or fleeing the Shadow leaves the
		-- character somewhere with nothing streamed in, and the farm then sat on
		-- "no reachable node" - 143 times in five minutes, the single biggest
		-- stall in the log. The fix is to go somewhere else and let the world
		-- load, not to keep asking.
		note("nothing loaded here - relocating")
		local root = hrp()
		local G = round()
		local anchor = G and (G:FindFirstChild("Buildings") and G.Buildings:FindFirstChildWhichIsA("BasePart", true))
		if root then
			local base = anchor and anchor.Position or root.Position
			local a = (os.clock() * 1.7) % (math.pi * 2)
			local r = 120 + (os.clock() * 37) % 260
			root.CFrame = CFrame.new(base + Vector3.new(math.cos(a) * r, 12, math.sin(a) * r))
			root.AssemblyLinearVelocity = Vector3.zero
		end
		task.wait(1.5)
		return
	end

	note("felling " .. tostring(node:GetAttribute("resourceId")))
	-- fellNode already collects while it is still standing at the node; doing
	-- it again from back here would only send refusals.
	local ok, why, picked = fellNode(node)
	if ok then
		note(string.format("felled, +%d, bag %d/%d", picked or 0, bagCount(), bagCap()))
	else
		note("miss: " .. tostring(why))
		task.wait(0.4)
	end
end)

-- The four artifacts. They gate the boat just as hard as the materials do, and
-- they are cheap early: on day 1 the blocks hold only a handful of mobs, and the
-- whole sweep took about three minutes. Left until later the same blocks are
-- full again, so this runs BEFORE the grind rather than after it.
local partsDone = false
loop(12, "autoParts", function()
	if partsDone or not round() or not alive() then return end
	if CONFIG.nightSafety and STATE.phase == "night" then return end
	local BE = svc("BoatExtra")
	if BE and BE.client and BE.client.requiresGet then
		local ok, got = pcall(function() return BE.client.requiresGet:InvokeServer() end)
		-- requiresGet returns what the boat HAS, not what it lacks - the name
		-- reads the other way round and cost a full debugging round.
		if ok and type(got) == "table" and #got >= 4 then
			partsDone = true
			note("all four artifacts secured")
			return
		end
	end
	note("fetching boat artifacts")
	fetchBoatParts()
end)

-- MrBeast quests: the tool ladder comes from here, so this outranks farming
-- whenever we are carrying what he asked for.
loop(6, "autoQuest", function()
	if not round() or not alive() then return end
	if CONFIG.nightSafety and STATE.phase == "night" then return end
	local want = questWants()
	if not want then return end
	local have = bagContents()[want.display] or 0
	if have < want.count then return end
	local ok, why = giveToMrBeast()
	if ok then note("MrBeast quest done") elseif why and why ~= "busy" then log("mrbeast: %s", why) end
end)

-- Loot boxes. Run when the bag has room; the drops are worth more per trip than
-- another tree, and a chest can hand over the tool the whole ladder is waiting
-- on.
-- Loot boxes are a BONUS, never the critical path. At a 3s interval they held
-- the hand almost continuously - 24 chests opened and not one tree felled in
-- four minutes, while the campfire sat at 0/5 wood. They only run when nothing
-- on the build path is waiting on us, or on a slow tick otherwise.
local lastChest = 0
loop(2, "autoChests", function()
	if not round() or not alive() then return end
	if CONFIG.nightSafety and STATE.phase == "night" then return end
	if bagFull() then return end
	-- Can we actually gather what the build plan wants? Needing Stone while the
	-- only tool is an axe is a hard stall - and a loot box is the way out of it,
	-- because that is where the pickaxes come from. So when we are gated on a
	-- missing tool, chests stop being a bonus and become the priority.
	local need = neededStock()
	local owned = ownedTools()
	local gated = false
	if need then
		gated = true
		for _, group in ipairs(WANT) do
			if need[group.stock] then
				for _, id in ipairs(group.ids) do
					local row = resourceRow(id)
					if row and (row.requireToolType == "any" or owned[row.requireToolType]) then
						gated = false
					end
				end
			end
		end
	end
	local gap = (need and not gated) and CONFIG.chestGapWhenBusy or 2
	if gated then STATE.note = "gated on a missing tool - looting for one" end
	if os.clock() - lastChest < gap then return end
	lastChest = os.clock()
	local ok, info = lootChest()
	if ok then note(string.format("chest opened, +%s", tostring(info))) end
end)

-- Sweep up anything WORTH HAVING lying around near us even when we did not fell
-- it. This ran with no filter at all every four seconds, which is how the Eggs,
-- the Meat and the Spider Web got into a bag that had no room for stone - and
-- how the same refused armour got retried until the screen was three speech
-- bubbles deep in "I already have a better armour".
loop(4, "autoCollect", function()
	if not round() or not alive() then return end
	collectDrops(nil, 40, wantFilter)
end)

-- Tool ladder, then the buildings, then the boat.
--
-- THIS is the red text. Firing all six recipes every six seconds meant five of
-- them were unaffordable every time, and each refusal prints "Insufficient
-- Materials" and "Not enough wood!" across the middle of the screen - the
-- screenshot the player sent has three lines of it stacked up. The loop was
-- doing exactly what it was written to do and still made the game unwatchable.
--
-- Recipe costs are read from Config rather than listed here, so this stays
-- right if the game rebalances. Note the literal mapping: for CRAFTING,
-- require_ironIngot means an Iron Ingot in the bag, not the Iron Ore that
-- RECIPE_FIELDS deliberately maps it to for the build plan.
local CRAFT_COST = {
	{ field = "require_wood",      stock = "Wood" },
	{ field = "require_stone",     stock = "Stone" },
	{ field = "require_ironIngot", stock = "Iron Ingot" },
}

local function canAfford(id)
	local byId = Config and Config.recipe and Config.recipe.byId
	local recipe = byId and (byId[id] or byId[id .. "配方"])
	if type(recipe) ~= "table" then return false end
	local have = bagContents()
	for _, spec in ipairs(CRAFT_COST) do
		local cost = recipe[spec.field] or 0
		if cost > 0 and (have[spec.stock] or 0) < cost then return false end
	end
	return true
end

loop(6, "autoCraft", function()
	if not round() or not alive() then return end
	local owned = ownedTools()
	for _, id in ipairs(TOOL_LADDER) do
		local row = Config and Config.tool and Config.tool.byId and Config.tool.byId[id]
		-- Do not re-craft a tier we already match or beat. The ladder is
		-- strictly increasing, so the tool in hand is the whole test.
		local mine = row and owned[row.toolType]
		local outclassed = mine and (mine.row.useDmg or 0) >= (row.useDmg or 0)
		if not outclassed and canAfford(id) then craft(id) end
	end
end)

loop(8, "autoBuild", function()
	if not round() or not alive() then return end
	if bagCount() == 0 then return end
	local pending = pendingConstructs()
	neededStock() -- refreshes constructNeeds

	-- What we are actually carrying, counting STACKS properly.
	local carrying = bagContents()

	local tried = {}
	local function deliver(id, model)
		if tried[id] then return false end
		tried[id] = true
		-- Only deliver if this site wants something we hold. Skipping this is
		-- what painted the screen red.
		local wants = constructNeeds[tostring(id):lower()]
		if not wants then return false end
		local match = false
		for stock in pairs(wants) do
			if carrying[stock] then match = true break end
		end
		if not match then return false end

		-- STAND AT THE SITE FIRST. Every other server-checked action in this
		-- game is validated against the server's own copy of our position -
		-- collectDrops needs it, addWood needs it, furnaceTick needs it - and
		-- this one was firing build() from wherever the last tree happened to
		-- be. That is the "bag full and nothing to unload" in the log: 44 times
		-- in one round, against 12 deliveries that only landed because the
		-- character happened to be standing in camp at the time.
		local part = model and model:FindFirstChildWhichIsA("BasePart", true)
		local before = bagCount()
		if part then
			withPin(part.Position, CONFIG.settleTime, function()
				build(id)
				task.wait(0.6)
			end, true)
		else
			build(id)
			task.wait(0.6)
		end

		if bagCount() < before then
			note(string.format("delivered %d to %s", before - bagCount(), id))
			return true
		end
		return false
	end

	for _, id in ipairs(BUILD_ORDER) do
		local m = pending[tostring(id):lower()]
		if m and deliver(id, m) then
			STATE.deliverFailed = false
			return
		end
	end
	-- Fallback: something is open that is not on the list. Feed it anyway
	-- rather than sitting on a full bag.
	for name, m in pairs(pending) do
		if deliver(name, m) then
			STATE.deliverFailed = false
			return
		end
	end
	-- Nothing took anything. Remembered so the farm loop knows the bag is dead
	-- weight and can burn it rather than idling.
	STATE.deliverFailed = true
	-- Keep the fire alive: it halves incoming mob damage and their walk speed,
	-- and it is the only way to cook.
	if CONFIG.keepFireLit and not campfireLit() then
		local ok, why = feedFire()
		if ok then note("campfire lit") elseif why ~= "already lit" then note("fire: " .. tostring(why)) end
	end
end)

loop(10, "autoBoat", function()
	if not round() or not alive() then return end
	build("boat")
end)

-- Smelting is the last gate before the boat: 10 ingots, 10s each, and an ingot
-- is ironOre + wood. Run it whenever we are carrying both.
loop(8, "autoSmelt", function()
	if not round() or not alive() then return end
	if not furnaceBuilding() then return end
	local have = {}
	for _, t in ipairs(plr.Backpack:GetChildren()) do have[t.Name] = true end
	-- collectResult is worth firing even with an empty bag: a finished ingot is
	-- sitting in the furnace waiting to be taken out.
	if not (have["Iron Ore"] and have["Wood"]) and not bagFull() then
		local f = furnaceBuilding()
		local part = f and f:FindFirstChildWhichIsA("BasePart", true)
		if part and furnaceFolder then
			local collect = furnaceFolder:FindFirstChild("collectResultRemote")
			if collect then
				withPin(part.Position, CONFIG.settleTime, function()
					if Furnace and Furnace.client then pcall(Furnace.client.collectResult)
					else pcall(function() collect:FireServer() end) end
				end)
			end
		end
		return
	end
	local how = furnaceTick()
	note("furnace: " .. tostring(how))
end)

-- Escape is the payout and it ENDS the round, so it is off by default.
--
-- `GameResult.client.escape()` returns cleanly and does nothing. The boat gets a
-- ProximityPrompt "Escape Island" once it is finished - materials AND the four
-- artifacts - and firing THAT is what ends the round. Verified: escapeCount
-- 0 -> 1, Diamonds 54 -> 56 (+2, exactly misc.escape_reward_diamonds), result
-- screen "Escaped", Survived Days 5, 18m51s, 156 mobs.
local function escapePrompt()
	local G = round()
	local b = G and G:FindFirstChild("Buildings")
	local boat = b and b:FindFirstChild("Boat")   -- not Boat_Construct
	if not boat then return nil end
	for _, d in ipairs(boat:GetDescendants()) do
		if d:IsA("ProximityPrompt") and d.ActionText == "Escape Island" then return d end
	end
	return nil
end

local function escapeIsland()
	local p = escapePrompt()
	if not p or not p.Enabled then return false, "boat not finished" end
	local anchor = p.Parent
	if not anchor:IsA("BasePart") then anchor = anchor:FindFirstChildWhichIsA("BasePart", true) end
	if not anchor then return false, "no anchor" end
	local done = false
	withHand("escape", function()
		withPin(anchor.Position, CONFIG.settleTime, function()
			pcall(function() fireproximityprompt(p) end)
			task.wait(2.5)
			done = true
		end, true)
	end, 5)
	if done then
		STATE.escapes = (STATE.escapes or 0) + 1
		note("ESCAPED - +2 diamonds")
	end
	return done
end

loop(5, "autoEscape", function()
	if not round() or not alive() then return end
	escapeIsland()
end)

-- Keep the bag to what the plan actually wants. wantFilter stops new trash
-- coming in; this is what gets the old trash out again, and without it the two
-- Eggs the player kept pointing at simply rode along for the whole round -
-- the bag-full handler was the only route out, and an upgraded 15-slot bag is
-- never full.
loop(15, "autoTidy", function()
	if not round() or not alive() then return end
	tidyBag()
end)

-- The MrBeast choice panel. It offers a few items every so often, and one of
-- them is often a BIGGER BAG - 5 slots to 15 to 25, which is the single largest
-- throughput change available in a round, and the player had been clicking it
-- by hand.
--
-- Driven through the cell's own ReceiveButton rather than
-- MrbeastChoice.client.selectChoice, so the game's real handler runs with
-- whatever the cell closure captured and no argument has to be guessed. That is
-- the technique the reverse-engineering notes recommend, and it is why nothing
-- here needs to know the choice's internal id.
--
-- The "Select All" button beside the cells carries a price of 25 and is NEVER
-- touched. That is the persistent currency; spending it is the player's call.
local function choiceCells()
	local pg = plr:FindFirstChildOfClass("PlayerGui")
	local g = pg and pg:FindFirstChild("MrbeastChoice")
	if not g or not g.Enabled then return nil end
	local bg = g:FindFirstChild("Background")
	if not bg or not bg.Visible then return nil end
	local scroll = bg:FindFirstChild("BadgeScroll", true)
	if not scroll then return nil end
	local out = {}
	for _, cell in ipairs(scroll:GetChildren()) do
		if cell.Name == "itemCell" and cell:IsA("GuiObject") and cell.Visible then
			local owned = cell:FindFirstChild("Owned")
			if not (owned and owned.Visible) then
				local btn, label
				for _, d in ipairs(cell:GetDescendants()) do
					if d.Name == "ReceiveButton" and d:IsA("GuiButton") then btn = d end
					-- Several labels are named `text`; the item name is the one
					-- that is not the word on the button itself.
					if d.Name == "text" and d:IsA("TextLabel") and d.Text ~= "Select"
					   and d.Text ~= "Owned" then label = d.Text end
				end
				if btn and label then out[#out + 1] = { btn = btn, name = label } end
			end
		end
	end
	return out
end

-- Bag first, then a tool that actually beats what is in hand, then armour, then
-- anything. A bag is worth more than any single tool here: the whole farm loop
-- is throttled by how much can be carried per trip.
local function choiceScore(name)
	if bagUpgrade(name) then
		local row = bagRowByName(name)
		return 1000 + ((row and row.cap) or 0)
	end
	local t = Config and Config.tool and Config.tool.byDisplayName and Config.tool.byDisplayName[name]
	if t then
		local mine = ownedTools()[t.toolType]
		local now  = mine and ((mine.row.useDmg or 0) + (mine.row.atkDmg or 0)) or 0
		local gain = ((t.useDmg or 0) + (t.atkDmg or 0)) - now
		return gain > 0 and (500 + gain) or 10
	end
	local a = Config and Config.armour and Config.armour.byDisplayName and Config.armour.byDisplayName[name]
	if a then
		local h = hum()
		local base = (Config and Config.misc and Config.misc.plrMaxHp) or 100
		local worn = h and math.max(0, (h.MaxHealth or base) - base) or 0
		return (a.hpIncrease or 0) > worn and (200 + (a.hpIncrease or 0)) or 5
	end
	return 1
end

-- MouseButton1Click, NOT Activated. Both carry exactly one connection, and
-- firing Activated alone did nothing at all: the panel stayed open and the loop
-- re-fired it every two seconds, logging "took Wooden Pickaxe" over and over
-- while nothing was taken. Measured - firing MouseButton1Click once took the
-- cell count from 1 to 0 and closed the panel. Activated is fired too, in case
-- a future cell wires it up instead, but the click is the one that works.
local choiceTries = 0

loop(2, "autoChoice", function()
	local cells = choiceCells()
	if not cells or #cells == 0 then choiceTries = 0 return end

	-- Do not hammer a panel that will not close. Three attempts is enough to
	-- rule out a dropped click; past that something is different and spamming
	-- it only makes the game unusable, which is the mistake this script has
	-- already made once with the craft loop.
	if choiceTries >= 3 then return end
	choiceTries = choiceTries + 1

	local best
	for _, c in ipairs(cells) do
		c.score = choiceScore(c.name)
		if not best or c.score > best.score then best = c end
	end
	if not best then return end

	local fired = 0
	for _, ev in ipairs({ "MouseButton1Click", "Activated" }) do
		local ok, conns = pcall(function() return getconnections(best.btn[ev]) end)
		if ok and conns then
			for _, cn in ipairs(conns) do
				if pcall(function() cn:Fire() end) then fired = fired + 1 end
			end
		end
	end
	if fired == 0 then
		log("MrBeast choice: %s offered but no handler to fire", best.name)
		return
	end

	task.wait(1)
	local still = choiceCells()
	if not still or #still == 0 then
		choiceTries = 0
		log("MrBeast choice: took %s", best.name)
		note("chose " .. best.name)
	end
end)

-- Death -> lobby -> next round, without a human in the loop.
--
-- Measured API, not guessed: MatchRoom.client.startGame() takes no arguments,
-- and ReplayService.client.voteYes() is the "play again" vote. Off by default,
-- because starting a round is an action other people in the room feel, and the
-- cooldown is there so a half-built lobby is never spammed.
local MatchRoom = (function()
	local A = ReplicatedStorage:FindFirstChild("Module")
	A = A and A:FindFirstChild("Addons")
	A = A and A:FindFirstChild("MatchRoom")
	if not A then return nil end
	local ok, m = pcall(require, A)
	return ok and m or nil
end)()
local Replay = svc("ReplayService")

local lastStart = 0
task.spawn(function()
	while live() do
		-- LEAVING A LOST ROUND IS ITS OWN SWITCH, and it is on by default.
		--
		-- Dying used to strand the script completely: the death screen halts
		-- every loop (correctly - a dead character is refused by every remote in
		-- silence, which is exactly what made the game look server-broken for a
		-- whole debugging round here), and the only way out was gated behind
		-- autoRejoin, which is off. So a death meant standing on the death
		-- screen until a human clicked.
		--
		-- Splitting it out is deliberate: leaving a round you already lost costs
		-- nobody anything, while STARTING one is an action other people in the
		-- room feel - so that half stays behind autoRejoin.
		if CONFIG.autoLobbyOnDeath and round() and not alive() then
			pcall(function()
				-- Take the FREE way out. The green Revive says "teammates can
				-- revive you within 60s" - solo that means Robux, and the
				-- player carries a `robuxReviveCount` attribute to prove it - so
				-- it is never touched.
				local ds = plr:FindFirstChild("PlayerGui")
				ds = ds and ds:FindFirstChild("DeathScreen")
				local bg = ds and ds:FindFirstChild("bg")
				if bg and bg.Visible then
					STATE.note = "dead - leaving to lobby"
					press(bg:FindFirstChild("goLobbyBtn"))
					task.wait(1.2)
					local rc = ds:FindFirstChild("returnConfirm")
					if rc and rc.Visible then press(rc:FindFirstChild("YESBtn")) end
					task.wait(1.2)
					-- The room may also ask whether to play the round again.
					local rv = ds:FindFirstChild("replayVote")
					if rv and rv.Visible then press(rv:FindFirstChild("YESBtn")) end
				end
			end)
			task.wait(2)
		end

		if CONFIG.autoRejoin then
			local ok = pcall(function()
				-- Only ever start from the lobby.
				if round() then return end
				if not inLobby() then return end
				if os.clock() - lastStart < CONFIG.rejoinCooldown then return end
				lastStart = os.clock()
				STATE.note = "lobby - starting a round"

				-- The measured flow, and every step of it matters:
				--   1. stand on a Room's Spawn part (a real position, the room
				--      counts you only while you are on it),
				--   2. the Create Party dialog appears,
				--   3. pick a party size - 1 for solo,
				--   4. press Create.
				-- `MatchRoom.client.startGame()` returns true and does nothing;
				-- the START button belongs to the party HUD and stays invisible
				-- until a party exists. Both were dead ends.
				local L = workspace:FindFirstChild("Lobby")
				local rooms = L and L:FindFirstChild("MatchRooms")
				local room = rooms and rooms:GetChildren()[1]
				local spawnPart = room and room:FindFirstChild("Spawn", true)
				local root = hrp()
				if not (spawnPart and root) then return end

				local pinned = true
				local conn = RunService.Heartbeat:Connect(function()
					if pinned and root.Parent then
						root.CFrame = CFrame.new(spawnPart.Position + Vector3.new(0, 4, 0))
					end
				end)
				task.wait(2)

				local mr = plr:FindFirstChild("PlayerGui")
				mr = mr and mr:FindFirstChild("MatchRoom")
				local cr = mr and mr:FindFirstChild("createRoom")
				local sizes = cr and cr:FindFirstChild("roomSizeBtns")
				local sizeBtn = sizes and sizes:FindFirstChild(tostring(CONFIG.partySize))
				local createBtn = cr and cr:FindFirstChild("createBtn")
				if sizeBtn then press(sizeBtn) task.wait(0.6) end
				if createBtn then press(createBtn) end

				-- Hold until the world folder flips, then let go.
				local t0 = os.clock()
				while os.clock() - t0 < 25 and workspace:FindFirstChild("Lobby") do task.wait(0.25) end
				pinned = false
				conn:Disconnect()
			end)
			if not ok then STATE.note = "rejoin failed" end
		end
		task.wait(2)
	end
end)

-- Codes, once per run.
task.spawn(function()
	if not CONFIG.redeemCodes then return end
	task.wait(6)
	local pkg = ReplicatedStorage:FindFirstChild("Packages")
	local rf = pkg and pkg:FindFirstChild("_Index")
	if not rf then return end
	local redeem
	for _, d in ipairs(rf:GetDescendants()) do
		if d.Name == "RF/RedeemCodeRedeem" then redeem = d break end
	end
	if not redeem or not Config or not Config.codes then return end
	for _, row in ipairs(Config.codes.list or {}) do
		if not live() then return end
		pcall(function() redeem:InvokeServer(row.code) end)
		task.wait(1.5)
	end
	note("codes redeemed")
end)

--------------------------------------------------------------- surviving a round start
-- Starting a round teleports to a reserved server and THAT CLEARS THE LUA VM -
-- measured: the script vanished the moment autoRejoin created the party, taking
-- its own automation with it. So it has to re-arm itself on the other side, the
-- same way hub/loader.lua does.
--
-- Armed once per run: queue_on_teleport APPENDS, so arming twice would load two
-- copies and build two panels.
if not _G.__ISLAND_QUEUED then
	_G.__ISLAND_QUEUED = true
	local q = queue_on_teleport or (syn and syn.queue_on_teleport)
	if q then
		pcall(function()
			q([[
				task.spawn(function()
					for _ = 1, 60 do
						if game:GetService("ReplicatedStorage"):FindFirstChild("Engine") then break end
						task.wait(1)
					end
					pcall(function() loadstring(readfile("islandescape.lua"))() end)
				end)
			]])
			log("armed queue_on_teleport - will survive the round start")
		end)
	else
		log("no queue_on_teleport on this executor - reload by hand after a round start")
	end
end

------------------------------------------------------------------------- debug
-- Set BEFORE the panel is built, on purpose. The panel reads files, may fetch a
-- language pack and asks the PC/Handy question the first time - all of which can
-- yield. Publishing the handle first means the farm and the bodyguard are usable
-- (and debuggable through the bridge) even if the interface never comes up.
_G.__ISLAND_DBG = {
	CONFIG = CONFIG, STATE = STATE,
	fellNode = fellNode, nextNode = nextNode, collectDrops = collectDrops,
	craft = craft, build = build, bagCount = bagCount, withPin = withPin,
	round = round, alive = alive, ownedTools = ownedTools, equipFor = equipFor,
	canHarvest = canHarvest, bagCap = bagCap, bagFull = bagFull,
	defend = defend, hostilesNear = hostilesNear, bestWeapon = bestWeapon,
	eatIfHungry = eatIfHungry, foodInBag = foodInBag, hunger = hunger,
	furnaceTick = furnaceTick, huntFood = huntFood,
	campfire = campfire, campfireLit = campfireLit, feedFire = feedFire,
	lootChest = lootChest, nextChest = nextChest, pendingConstructs = pendingConstructs,
	neededStock = neededStock, burnWoodForSpace = burnWoodForSpace,
	readGameText = readGameText, furnaceBuilding = furnaceBuilding,
	bagContents = bagContents, storeSurplus = storeSurplus, log = log,
	wantFilter = wantFilter, dropStack = dropStack, canAfford = canAfford,
	skipDrop = skipDrop, dropSkipped = dropSkipped, cutscene = cutscene,
	carryJunk = carryJunk, tidyBag = tidyBag, bagUpgrade = bagUpgrade,
	stackItem = stackItem,
	choiceCells = choiceCells, choiceScore = choiceScore, myBagLvl = myBagLvl,
	fetchBoatParts = fetchBoatParts, clearPartBlock = clearPartBlock,
	giveToMrBeast = giveToMrBeast, questWants = questWants, mrbeastNpc = mrbeastNpc,
	escapeIsland = escapeIsland, escapePrompt = escapePrompt,
	mobsInBlock = mobsInBlock, blockOf = blockOf, collectPrompt = collectPrompt,
	withHand = withHand, press = press,
}
_G.__ISLAND_STEP = "core ready"

------------------------------------------------------------------------ panel
task.spawn(function()
local okPanel, panelErr = pcall(function()

local UI = (_G.__SEL and _G.__SEL.ui) or loadstring(readfile("ui-template.lua"))()
UI.config("islandescape", CONFIG)
_G.__ISLAND_STEP = "template loaded"

-- Re-running the script leaves the PREVIOUS panel on screen: the generation
-- counter stops the old loops but nothing destroys its ScreenGui, so every
-- reload stacked another window. Naming the gui makes the old one findable.
-- Panels built before this cleanup existed carry the template's random fallback
-- name ("Selux_" plus digits), so matching only our own name left three windows
-- stacked on screen. Sweep both: our fixed name, and any unnamed Selux panel -
-- an unnamed one can only come from a script that passed no name, which in this
-- game is an older copy of this script.
local GUI_NAME = "Selux_islandescape"
for _, parent in ipairs({ game:GetService("CoreGui"), plr:FindFirstChild("PlayerGui") }) do
	if parent then
		for _, g in ipairs(parent:GetChildren()) do
			if g:IsA("ScreenGui")
			   and (g.Name == GUI_NAME or g.Name:match("^Selux_%d+$")) then
				pcall(function() g:Destroy() end)
			end
		end
	end
end

local win = UI.Window({ title = "ISLAND", accentTitle = "ESCAPE", subtitle = "seltonmt", name = GUI_NAME })
win:Home()

local farm = win:Page("FARMING", UI.icon.pickaxe)
local c1 = farm:Card("RESOURCES", 1):Accent()
c1:Toggle("Chop trees", CONFIG.farmWood, function(v) CONFIG.farmWood = v end,
	"Wood for the campfire, the workbench and the boat")
c1:Toggle("Mine stone", CONFIG.farmStone, function(v) CONFIG.farmStone = v end,
	"Needs a pickaxe - the server checks the tool type")
c1:Toggle("Mine iron", CONFIG.farmIron, function(v) CONFIG.farmIron = v end,
	"Iron ore is smelted into ingots for the boat")
c1:Toggle("Pick up drops", CONFIG.autoCollect, function(v) CONFIG.autoCollect = v end,
	"Collect what a felled node leaves behind")
c1:Toggle("Open loot boxes", CONFIG.autoChests, function(v) CONFIG.autoChests = v end,
	"27 sit in a fresh map and can hand over the tool you are waiting on")

local c2 = farm:Card("SPEED", 2)
c2:Toggle("Fast harvest", CONFIG.fastHarvest, function(v) CONFIG.fastHarvest = v end,
	"One call per node instead of one swing at a time", UI.theme.warn)
c2:Slider("Settle time", 0.4, 2.0, CONFIG.settleTime, function(v) CONFIG.settleTime = v end,
	"How long to hold position before the hit is sent")

local prog = win:Page("PROGRESS", UI.icon.wrench)
local c3 = prog:Card("BUILD", 1):Accent()
c3:Toggle("Craft tool ladder", CONFIG.autoCraft, function(v) CONFIG.autoCraft = v end,
	"Wooden, then stone, then iron axe and pickaxe")
c3:Toggle("Build camp", CONFIG.autoBuild, function(v) CONFIG.autoBuild = v end,
	"Campfire, crafting table, storage, furnace")
c3:Toggle("Build the boat", CONFIG.autoBoat, function(v) CONFIG.autoBoat = v end,
	"20 wood, 20 stone, 10 iron ingots")
c3:Toggle("Smelt iron ingots", CONFIG.autoSmelt, function(v) CONFIG.autoSmelt = v end,
	"Iron ore plus wood in the furnace, ten seconds each")
c3:Toggle("Fetch the four artifacts", CONFIG.autoParts, function(v) CONFIG.autoParts = v end,
	"Map, Radio, Compass and Bucket - the boat needs them too")
c3:Toggle("Do MrBeast quests", CONFIG.autoQuest, function(v) CONFIG.autoQuest = v end,
	"His first quest pays the pickaxe the tool ladder is stuck behind")

local c4 = prog:Card("ROUND", 2)
c4:Toggle("Escape when ready", CONFIG.autoEscape, function(v) CONFIG.autoEscape = v end,
	"Ends the round and pays 2 diamonds", UI.theme.warn)
c4:Toggle("Hold still at night", CONFIG.nightSafety, function(v) CONFIG.nightSafety = v end,
	"Stop farming while the night hunts")
c4:Toggle("Redeem codes", CONFIG.redeemCodes, function(v) CONFIG.redeemCodes = v end,
	"Redeems every code in the game's own config")
c4:Toggle("Start a new round by itself", CONFIG.autoRejoin, function(v) CONFIG.autoRejoin = v end,
	"After a death, waits in the lobby and starts the next round", UI.theme.warn)

local c5 = prog:Card("SAFETY", 0):Accent()
c5:Toggle("Kill what comes close", CONFIG.autoDefend, function(v) CONFIG.autoDefend = v end,
	"Runs even with the master switch off, so nothing kills you while you wait",
	UI.theme.good)
c5:Slider("Guard radius", 20, 120, CONFIG.defendRadius, function(v) CONFIG.defendRadius = v end,
	"How far to look for something hostile")
c5:Toggle("Eat when hungry", CONFIG.autoEat, function(v) CONFIG.autoEat = v end,
	"Health only regenerates above half hunger - starving is what kills you idle",
	UI.theme.good)
c5:Slider("Eat below", 20, 95, CONFIG.eatBelowHunger, function(v) CONFIG.eatBelowHunger = v end,
	"Hunger level that triggers a meal")
c5:Toggle("Run from the Shadow", CONFIG.evadeShadow, function(v) CONFIG.evadeShadow = v end,
	"It has a million health - there is nothing to fight, so leave",
	UI.theme.good)
c5:Toggle("Hold still at night", CONFIG.nightSafety, function(v) CONFIG.nightSafety = v end,
	"Off by default: night is a third of the round and hovering is safe")

win:Settings()

win:OnMaster(function(on) CONFIG.auto = on end)
win:SetMaster(CONFIG.auto, "Auto farm running")

task.spawn(function()
	while live() do
		win:SetStat(1, tostring(STATE.felled), "felled")
		win:SetStat(2, tostring(STATE.collected), "picked up")
		win:SetStat(3, tostring(STATE.bag), "in bag")
		local h = hum()
		win:SetStatus(string.format("day %d   %s   %ds   hp %d   food %d   %s",
			STATE.day, STATE.phase, STATE.remain,
			math.floor(h and h.Health or 0), math.floor((hunger())), STATE.note))
		task.wait(0.5)
	end
end)

_G.__ISLAND_STEP = "panel up"
end)
if not okPanel then
	_G.__ISLAND_STEP = "panel failed: " .. tostring(panelErr)
	STATE.note = "panel failed - farm still running"
end
end)

return _G.__ISLAND_DBG
