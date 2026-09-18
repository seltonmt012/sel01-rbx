--[[ phantomforces.lua - Phantom Forces (StyLiS Studios), place 292439477

  ESP, aim assist and a trigger for the one shooter in this hub that actively
  fights being read. Nothing here fires a remote, requires a module or touches
  the game's Actor VM: every value below comes out of Instances, and the two
  inputs go through the real mouse.

  ============================================================================
  WHAT PHANTOM FORCES DOES TO SCRIPTS, all measured 2026-09-18 on a live server
  ============================================================================

  1. EVERY NAME IS A RANDOM STRING, including the ones you would never check.
     `game.Players` THROWS - "Players is not a valid member of DataModel" -
     because the service is renamed (`hUfmmK^` that session). The DataModel
     itself reads `Ugc` one minute and `JM[RzIP7lZf` the next. The team folders,
     the character models and every part in them are random too.

     So: `game:GetService(...)` everywhere, never `game.X`, and nothing in this
     file looks anything up by name except the handful of REAL names the game
     cannot obfuscate because its own GUI templates use them (`NameTagGui`,
     `PlayerTag`, the HUD labels).

  2. THERE IS NO ROBLOX CHARACTER. `Player.Character` is nil for everybody,
     `Player.Team` is nil and the Teams service is EMPTY. The real bodies are
     Models in `workspace.Players.<team folder>.<model>`, and each one is six
     parts of 0.001 studs (the replicated skeleton) plus a folder of ~18
     MeshParts (what you actually see).

  3. THE MODELS ARE DESTROYED AND REBUILT CONSTANTLY. Measured with
     ChildAdded/ChildRemoved on both folders: 55 adds and 52 removes in 15
     seconds with 15 players on the server. A model reference is worthless
     within a few seconds, so nothing here caches one: the ESP pool is keyed by
     PLAYER NAME and the world is re-enumerated every frame. Cheap - two
     folders, fifteen models.

  4. THE IDENTITY IS IN THE NAMETAG, AND SO IS THE HEAD. Every model carries a
     `NameTagGui` BillboardGui whose `PlayerTag` TextLabel holds the real player
     name - both teams, whether the tag is visible or not. And the PART IT HANGS
     ON IS THE HEAD: verified against the six parts sorted by height, the tag
     holder was the topmost every time. That is the whole rig problem solved
     without a single name match.

  5. HEALTH DOES NOT REPLICATE RELIABLY. The nametag has a `Health` frame with a
     `Percent` bar, and it is present on some reads and absent on others - 15
     tags in one sweep, zero of them carrying it. So this script shows health
     WHEN THE GAME ITSELF PUBLISHES IT and draws nothing otherwise, rather than
     printing a made-up 100.

  6. THE CAMERA FIGHTS BACK. CameraType is Scriptable and the game rebuilds the
     CFrame from angles it keeps itself. Measured with eight 5 deg writes: the
     write survives the frame it is made in and is then thrown back - every
     following sample read 0.01-0.05 deg against the PREVIOUS orientation and
     ~5 deg against the wanted one. Same shape as BloxStrike, so the delivery
     default here is MOUSE, not camera. Auto still probes, in case a future
     update changes it.

  7. `keypress` IS A DEAD STUB. Probed with F13 and counted at
     UserInputService.InputBegan: keypress 0 arrived, mouse1click 1,
     VirtualInputManager 1 for both key and button. So the trigger uses
     mouse1click with a VirtualInputManager fallback, it PROBES which one works
     at start-up instead of preferring whichever exists, and the panel names the
     winner - a trigger that cannot fire looks exactly like one that is never
     armed.

  8. THE CLIENT RUNS IN AN ACTOR VM (getactors 1, getrunningscripts 0, 2702
     loaded modules). Nothing here needs it. It also means a __namecall hook in
     the main VM sees none of the game's traffic, so do not go looking for the
     shot path that way.

  What is NOT in here, on purpose: nothing writes health, position, speed or a
  hitbox size, and no remote is fired. Phantom Forces validates movement server
  side and has done for years; the honest camera-and-mouse toolkit is the whole
  offer.
]]

local Players          = game:GetService("Players")       -- NEVER game.Players here
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local GuiService       = game:GetService("GuiService")

local plr    = Players.LocalPlayer
local camera = workspace.CurrentCamera

workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
	if workspace.CurrentCamera then camera = workspace.CurrentCamera end
end)

--------------------------------------------------------------------------------
-- generation guard
--------------------------------------------------------------------------------
--
-- Re-executing does not restart the Lua VM. Every loop and render bind checks
-- this so last run's ghosts stop themselves.

_G.__SELPF = (_G.__SELPF or 0) + 1
local GEN = _G.__SELPF

--------------------------------------------------------------------------------
-- executor capabilities, resolved once
--------------------------------------------------------------------------------

-- NEVER rawget these. Potassium hands the executor globals out through the
-- sandbox env's __index metamethod, so `rawget(getfenv(), "mousemoverel")`
-- returns nil for a function that is right there and callable. That one line
-- cost the whole aim assist: with moveMouse nil the delivery fell back to the
-- CAMERA path, which this game throws away within a frame, and the panel
-- honestly reported "Camera" while the user reported "the aimbot does nothing".
-- Measured live: 10.30 deg of error converging to 2.62 and then climbing back to
-- 8.62 - the signature of a write being undone.
local function globalFn(name)
	for _, src in ipairs({
		function() return getgenv and getgenv()[name] or nil end,
		function() return getfenv()[name] end,
		function() return _G[name] end,
	}) do
		local ok, v = pcall(src)
		if ok and type(v) == "function" then return v end
	end
	return nil
end

local HAS_DRAWING = (Drawing ~= nil and Drawing.new ~= nil)
local moveMouse   = globalFn("mousemoverel")
local clickDown   = globalFn("mouse1press")
local clickUp     = globalFn("mouse1release")
local clickOnce   = globalFn("mouse1click")
local getHui      = globalFn("gethui")

local VIM = nil
pcall(function() VIM = game:GetService("VirtualInputManager") end)

--------------------------------------------------------------------------------
-- THE FFLAG, and why everything below depends on it
--------------------------------------------------------------------------------
--
-- Phantom Forces runs its whole client in an Actor VM. From the main Lua state
-- that is a wall: `getgc` cannot see its tables, `hookfunction` cannot bite on
-- its methods, and every packet it sends carries a rolling key that lives in
-- there as an upvalue. Measured before: getgc 388844 objects, getactors 1.
--
-- Roblox has a debug flag that puts parallel Lua on the main thread:
--
--     setfflag("DebugRunParallelLuaOnMainThread", "true")   -- then REJOIN
--
-- After the rejoin the same client reads getactors **0** and getgc **742648** -
-- the game's own state is now in reach. Everything on the GUN MODS page exists
-- only in that mode; the ESP, the aimbot, the triggerbot and the recoil
-- compensation work either way, so the script does not insist on it.
--
-- The flag only takes effect on a fresh join, which is why this is offered as a
-- button rather than done silently: it teleports the player back into the same
-- server and that is not something a panel should do behind their back.

local MODS = _G.__SELPF_MODS or {
	noRecoil = false, noSpread = false, noSway = false, noEquipTime = false,
	instantAds = false, rapidFire = false, fireRate = 1200,
	noBob = false, noSuppression = false, noBolt = false, stability = false,
	silent = false, fastReload = false, reloadFactor = 0.3,
}
_G.__SELPF_MODS = MODS

local HOOKS = _G.__SELPF_HOOKS or { installed = false, note = "not installed",
	statOverride = {}, weaponStat = false, recoil = 0, bent = {} }
HOOKS.bent = HOOKS.bent or {}
_G.__SELPF_HOOKS = HOOKS

local function fflagOn()
	local get = globalFn("getfflag")
	if not get then return nil end
	local ok, v = pcall(get, "DebugRunParallelLuaOnMainThread")
	if not ok then return nil end
	return tostring(v) == "true"
end

local function parallelOnMainThread()
	-- the flag being set is not the same as the client having rejoined with it;
	-- the actor count is the fact, the flag is only the intent
	local ok, n = pcall(function() return #getactors() end)
	return ok and n == 0
end

-- Forward declaration: the silent aim hook is installed long before the target
-- picker exists, and a Lua local is invisible above its own definition.
local silentAimPoint = nil

-- Install once per VM. hookfunction cannot be undone and hooking twice stacks
-- handlers permanently, so every hook here is installed exactly once and reads a
-- live flag out of MODS instead of being added and removed.
-- Bumped whenever a hook BODY changes. hookfunction cannot be undone, so a
-- re-execute cannot replace an installed hook - it can only stack a second one,
-- which is worse. The honest move is to detect that the live hooks are older
-- than this file and say so, because the alternative is a panel whose switches
-- quietly drive last version's code.
local HOOK_VERSION = 5

local function installHooks()
	if HOOKS.installed then
		if (HOOKS.version or 1) < HOOK_VERSION then
			HOOKS.note = "hooks are from an older load - rejoin to update them"
		end
		return HOOKS
	end
	if not globalFn("hookfunction") then
		HOOKS.note = "this executor has no hookfunction"
		return HOOKS
	end
	if not parallelOnMainThread() then
		HOOKS.note = "the client still runs its code in an Actor VM"
		return HOOKS
	end

	local hookfn = globalFn("hookfunction")
	local firearm, bullets, net, recoilTables = nil, nil, nil, {}
	local ok = pcall(function()
		for _, v in ipairs(getgc(true)) do
			if type(v) == "table" then
				if not firearm and type(rawget(v, "getWeaponStat")) == "function"
					and type(rawget(v, "fireRound")) == "function" then
					firearm = v
				end
				if not net and type(rawget(v, "send")) == "function"
					and type(rawget(v, "getPing")) == "function" then
					net = v
				end
				if not bullets and type(rawget(v, "newBullet")) == "function"
					and type(rawget(v, "cleanBullets")) == "function" then
					bullets = v
				end
				if type(rawget(v, "applyImpulse")) == "function" then
					recoilTables[#recoilTables + 1] = v
				end
			end
		end
	end)
	if not ok then
		HOOKS.note = "the object sweep failed"
		return HOOKS
	end

	-- NOT INSTALLED, JUST NOT READY. On a fresh join the hub loader runs this
	-- script before the game's own client has built its objects, so the sweep
	-- finds nothing - and marking that as "installed" burns the only chance to
	-- hook anything for the whole session. Measured exactly that way: a join came
	-- up reading "stats false, recoil on 0 tables" and every gun mod was dead
	-- with no error anywhere. Leave it retryable instead.
	if not firearm then
		HOOKS.note = "waiting for the game's client to finish loading"
		return HOOKS
	end

	-- Every gun mod except the recoil is a STAT LOOKUP. The weapon asks
	-- `getWeaponStat("hipfirespread")` and friends on every shot, so one hook on
	-- that single method covers spread, sway, equip time and ADS speed at once,
	-- and adding another mod later is a table entry rather than a new hook.
	if firearm then
		local old
		old = hookfn(firearm.getWeaponStat, function(self, name, ...)
			local ovr = HOOKS.statOverride
			if type(name) == "string" then
				local v = ovr[name]
				if v ~= nil then return v end
			end
			return old(self, name, ...)
		end)
		HOOKS.weaponStat = true
	end

	-- FASTER RELOAD. There is no reload TIME in the weapon stats - the duration
	-- IS the animation, and the state machine asks `getAnimLength(name)` for it
	-- (`getCurrentReloadLength` is just that call with the current reload file's
	-- name). Scaling the answer therefore shortens the reload state without
	-- touching the animation system.
	--
	-- Scoped to the reload on purpose: the same function answers for equipping,
	-- firing and bolt work, and shrinking all of it is how a script ends up
	-- feeling broken in ways nobody can describe.
	if firearm then
		local old
		old = hookfn(firearm.getAnimLength, function(self, name, ...)
			local real = old(self, name, ...)
			if not MODS.fastReload or type(real) ~= "number" or real <= 0 then
				return real
			end
			local isReload = false
			if type(name) == "string" and name:lower():find("reload", 1, true) then
				isReload = true
			else
				local okf, file = pcall(function() return self:getCurrentReloadFile() end)
				if okf and type(file) == "table" and file.reloadName == name then
					isReload = true
				end
			end
			if not isReload then return real end
			return real * math.clamp(MODS.reloadFactor or 0.3, 0.05, 1)
		end)
		HOOKS.reload = true
	end

	-- SILENT AIM, and it is the bullet that is bent - not the hit that is
	-- claimed. The first attempt replaced the answer of `playerHitCheck`, so the
	-- client reported a hit while the bullet flew somewhere else entirely: the
	-- packets went out on a valid key and the server confirmed **none** of them,
	-- because it re-validates the trajectory.
	--
	-- Rewriting `newBullet`'s velocity instead means the shot genuinely travels
	-- at the target. The game's own hit detection then finds the enemy the
	-- ordinary way, reports it the ordinary way, and the `newbullets` packet the
	-- client sends carries that same direction - there is nothing for the server
	-- to disagree with. This is the shape every open-source silent aim uses,
	-- usually by rewriting the direction argument of a raycast; Phantom Forces
	-- simulates its bullets instead of raycasting them, so the velocity is the
	-- equivalent place.
	if bullets then
		local old
		old = hookfn(bullets.newBullet, function(props, ...)
			-- Everything this hook touches is reached through HOOKS, which lives
			-- in _G. hookfunction cannot be undone, so after a re-execute the
			-- INSTALLED hook is still the first run's closure: a captured local
			-- would keep pointing at the old run's target picker and the old
			-- run's counters, and the panel would sit there reading zero while
			-- bullets were being bent. Measured exactly that way once.
			-- ONLY OUR OWN BULLETS. newBullet is called for every bullet in the
			-- world, remote players' replicated ones included - 208 of them in
			-- twelve seconds against a handful of our own - and bending those
			-- redirects other people's tracers on our screen for no gain.
			-- `extra.firearmObject` is set only by our own fireRound.
			local ours = type(props) == "table" and type(props.extra) == "table"
				and props.extra.firearmObject ~= nil
			if MODS.silent and ours
				and typeof(props.velocity) == "Vector3"
				and typeof(props.position) == "Vector3" then
				local pick = HOOKS.aimPoint
				local aim = pick and pick(props.position, props.velocity.Magnitude)
				if aim then
					local dir = aim - props.position
					if dir.Magnitude > 0.001 then
						local unit = dir.Unit
						props.velocity = unit * props.velocity.Magnitude
						HOOKS.silentShots = (HOOKS.silentShots or 0) + 1
						-- Remember it by TICKET, because the packet that tells the
						-- server about this shot is built separately from the
						-- bullet object and has to be given the same direction.
						local ticket = props.extra.bulletTicket
						if ticket then HOOKS.bent[ticket] = unit end
					end
				end
			end
			return old(props, ...)
		end)
		HOOKS.silent = true
	end

	-- THE OTHER HALF OF SILENT AIM, and without it the feature is a lie that the
	-- client tells itself. `fireRound` does not build the network packet from the
	-- bullet object - it collects `{ direction, ticket }` pairs from its own
	-- local and sends those:
	--
	--     v225[#v225 + 1] = { v232, v230 }
	--     NetworkClient:send("newbullets", uniqueId, v226, GameClock.getTime())
	--
	-- So bending the bullet alone makes the CLIENT hit - the hitmarker even
	-- appears, because the hitmarker is drawn by the client's own hit detection -
	-- while the server still sees a shot going the original way and refuses the
	-- damage. Reported exactly like that: "hitmarker comes, no damage". Matching
	-- the packet to the bullet by ticket is what closes it.
	if net then
		local old
		old = hookfn(net.send, function(self, name, uid, list, ...)
			-- The payload is a WRAPPER, not the list: `{ firepos = ..., index = ...,
			-- bullets = { {direction, ticket}, ... } }`. Iterating the wrapper
			-- finds no pairs at all and the rewrite silently does nothing, which
			-- read as "the bullet is bent but the packet is not" for a while.
			if name == "newbullets" and type(list) == "table" then
				local entries = (type(list.bullets) == "table") and list.bullets or list
				for _, entry in pairs(entries) do
					if type(entry) == "table" and typeof(entry[1]) == "Vector3" then
						local bent = entry[2] and HOOKS.bent[entry[2]]
						if bent then
							entry[1] = bent
							HOOKS.bent[entry[2]] = nil
							HOOKS.sentBent = (HOOKS.sentBent or 0) + 1
						end
					end
				end
			end
			return old(self, name, uid, list, ...)
		end)
		HOOKS.send = true
	end

	-- The camera kick. Measured over an eight round burst: 2.49 deg of climb
	-- with it, 0.01 deg with it hooked out.
	for _, t in ipairs(recoilTables) do
		local old
		old = hookfn(t.applyImpulse, function(...)
			if MODS.noRecoil then return end
			return old(...)
		end)
		HOOKS.recoil = HOOKS.recoil + 1
	end

	HOOKS.installed = true
	HOOKS.version = HOOK_VERSION
	HOOKS.note = "ok - stats " .. tostring(HOOKS.weaponStat)
		.. ", recoil on " .. HOOKS.recoil .. " tables"
		.. (HOOKS.silent and ", silent aim" or "")
	return HOOKS
end

-- The stat table is rebuilt from the toggles rather than patched in place, so a
-- switch turning OFF really removes its entry instead of leaving the last value
-- behind.
local SWAY_STATS = { "idleswayampaimmult", "idleswayamphipmult", "idleswaycyclespeed",
	"walkswayampaimmult", "walkswayamphipmult", "walkswayrotaimmult",
	"walkswayrothipmult" }

local function refreshStatOverride()
	local o = {}
	if MODS.noSpread then
		o.hipfirespread = 0
		o.hipfirespreadrecover = 100
	end
	if MODS.noSway then
		for _, k in ipairs(SWAY_STATS) do o[k] = 0 end
	end
	if MODS.noBob then
		-- the two the client asks for most often of anything: 4720 and 576
		-- lookups in eight seconds of ordinary play
		o.swingmod = 0
		o.aimswingmod = 0
	end
	if MODS.noSuppression then
		o.suppression = 0
	end
	if MODS.noBolt then
		o.requirechamber = false
		o.bolttime = 0.01
		o.boltlock = false
	end
	if MODS.stability then
		o.hipfirestability = 1
		o.aimkickmult = 0
	end
	if MODS.noEquipTime then
		o.equiptime = 0.01
		o.unequiptime = 0.01
	end
	if MODS.instantAds then
		o.aimspeed = 60
		o.unaimspeed = 60
		o.magnifyspeed = 60
		o.unmagnifyspeed = 60
	end
	if MODS.rapidFire then
		o.firerate = math.max(60, MODS.fireRate)
	end
	HOOKS.statOverride = o
end

--------------------------------------------------------------------------------
-- config
--------------------------------------------------------------------------------

local CONFIG = {
	-- targets --------------------------------------------------------------------
	teamMode   = "Auto",      -- Auto | Everyone
	teamInvert = false,
	maxDist    = 2000,

	-- esp ------------------------------------------------------------------------
	esp        = true,
	espBox     = true,
	espBoxFill = false,
	espName    = true,
	espInfo    = true,        -- distance
	espScore   = false,       -- kills/deaths off the leaderboard
	espHealth  = true,        -- only when the game publishes it, see header (5)
	espTracer  = false,
	espHeadDot = false,
	espSkeleton = false,
	espVisOnly = false,
	espDimHidden = true,
	espTextSize = 13,
	espFont    = 1,           -- the OS face - the only one hinted for small sizes

	-- chams ----------------------------------------------------------------------
	chams      = false,
	chamsFill  = 0.55,
	chamsOutline = 0.2,

	-- recoil control -------------------------------------------------------------
	rcs        = false,
	rcsPct     = 70,          -- how much of the measured kick is taken back
	rcsMaxDeg  = 4,           -- per-frame clamp, so nothing oscillates

	-- aim ------------------------------------------------------------------------
	aim        = false,       -- OFF by default: ESP is information, this is input
	aimActive  = "Hotkey",
	aimKey     = "MouseButton2",
	aimPart    = "Head",
	aimPick    = "Crosshair",
	aimDeliver = "Mouse",     -- measured: camera writes are thrown away here
	aimFov     = 110,
	aimSmoothH = 24,
	aimSmoothV = 28,
	aimSticky  = true,
	aimVisible = true,
	aimMaxDist = 1200,
	aimCircle  = true,
	aimPredict = true,        -- aim where the bullet ARRIVES, not where the head is
	aimLead    = true,        -- and lead a moving target

	-- silent aim - bends the BULLET, needs the FFlag ----------------------------
	silent     = false,
	silentPart = "Head",
	silentFov  = 250,          -- pixels from the crosshair
	silentMaxDist = 1500,
	silentVisible = true,
	silentLead = false,       -- off until the lead is proven, it can throw a shot
	silentCircle = true,

	-- movement and world --------------------------------------------------------
	speed      = false,
	speedMult  = 1.4,
	infStamina = false,
	fly        = false,
	flySpeed   = 60,
	fullbright = false,
	noFog      = false,
	noGrass    = false,

	-- gun mods - these need the FFlag and a rejoin, see the header --------------
	noRecoil   = false,
	noSpread   = false,
	noSway     = false,
	noEquipTime = false,
	instantAds = false,
	rapidFire  = false,
	fireRate   = 1200,
	noBob      = false,
	noSuppression = false,
	noBolt     = false,
	stability  = false,
	fastReload = false,
	reloadFactor = 0.3,

	-- trigger --------------------------------------------------------------------
	trg        = false,
	trgActive  = "Hotkey",
	trgKey     = "C",
	trgHeadOnly = false,
	trgVisible = true,
	trgMaxDist = 800,
	trgDelayMin = 90,
	trgDelayMax = 180,
	trgRefire  = 140,
	trgChance  = 92,
	trgFovPx   = 4,           -- a single centre ray only ever hits a standing target

	-- humanisation - THIS is the safety ------------------------------------------
	hum        = true,
	humReactMin = 90,
	humReactMax = 190,
	humRampMs  = 220,
	humNoise   = 0.4,
	humNoiseHz = 1.6,
	humDeadPx  = 3,
	humMaxDegS = 360,
	humPanelOff = true,
	panicKey   = "F1",

	-- colours --------------------------------------------------------------------
	colEnemy   = Color3.fromRGB(255, 86, 86),
	colVisible = Color3.fromRGB(120, 235, 140),
	colText    = Color3.fromRGB(240, 240, 240),
	colFov     = Color3.fromRGB(255, 255, 255),
	colSilentFov = Color3.fromRGB(255, 120, 60),
}

local PRESETS = {
	Legit = { aimSmoothH = 34, aimSmoothV = 40, aimFov = 70, humReactMin = 140,
		humReactMax = 260, humRampMs = 300, humNoise = 0.5, humDeadPx = 5,
		humMaxDegS = 200, hum = true, trgDelayMin = 130, trgDelayMax = 240,
		trgChance = 85 },
	Normal = { aimSmoothH = 24, aimSmoothV = 28, aimFov = 110, humReactMin = 90,
		humReactMax = 190, humRampMs = 220, humNoise = 0.4, humDeadPx = 3,
		humMaxDegS = 360, hum = true, trgDelayMin = 90, trgDelayMax = 180,
		trgChance = 92 },
	-- Raw means raw: smoothing 1 is a full correction every frame, which is what
	-- the name promises. It used to set 8 and 9, so picking it still gave a soft
	-- follow and read as "it never locks".
	Raw = { aimSmoothH = 1, aimSmoothV = 1, aimFov = 200, humReactMin = 0,
		humReactMax = 0, humRampMs = 0, humNoise = 0, humDeadPx = 0,
		humMaxDegS = 1200, hum = false, trgDelayMin = 0, trgDelayMax = 0,
		trgChance = 100 },
}

local STATE = {
	targets   = 0,
	alive     = 0,
	myTeam    = "-",
	teamNote  = "-",
	chain     = {},
	churn     = 0,        -- models rebuilt per second, see header (3)
	target    = "-",
	engaged   = false,
	waitMs    = 0,
	aimErr    = 0,
	deliver   = "-",
	stickPct  = -1,
	mouseSens = 0,
	rcsSens   = 0,        -- rad per mouse unit, learned from the player's own hand
	rcsKick   = 0,        -- the residual left after subtracting the player, in deg
	dropStuds = 0,        -- how far above the head the assist is aiming
	bulletSpeed = 0,      -- measured off our own echoed shot, 0 until one is fired
	weapon    = "-",
	silentShots = 0,      -- bullets whose direction was actually rewritten
	silentTarget = "-",
	speed      = 0,       -- the character's own reading, live
	snapFrames = 0,       -- frames the magnet actually held a part
	snapHits   = 0,       -- bulletHitConfirm since the magnet was switched on
	snapPartHits = 0,     -- ...of which named the part the magnet was holding
	clickWay  = "not probed",
	shots     = 0,
	hud       = "-",
	panelOpen = false,
	note      = "",
}

local function note(s) STATE.note = tostring(s) end

-- CONFIG is what the panel saves; MODS is what the hooks read. Keeping them
-- separate means a hook never has to know the panel exists, and one call puts
-- the two back in step.
local function syncMods()
	MODS.noRecoil    = CONFIG.noRecoil
	MODS.noSpread    = CONFIG.noSpread
	MODS.noSway      = CONFIG.noSway
	MODS.noEquipTime = CONFIG.noEquipTime
	MODS.instantAds  = CONFIG.instantAds
	MODS.rapidFire   = CONFIG.rapidFire
	MODS.fireRate    = CONFIG.fireRate
	MODS.noBob         = CONFIG.noBob
	MODS.noSuppression = CONFIG.noSuppression
	MODS.noBolt        = CONFIG.noBolt
	MODS.stability     = CONFIG.stability
	MODS.silent        = CONFIG.silent
	MODS.fastReload    = CONFIG.fastReload
	MODS.reloadFactor  = CONFIG.reloadFactor
	refreshStatOverride()
end

--------------------------------------------------------------------------------
-- the world layer: where Phantom Forces keeps its players
--------------------------------------------------------------------------------
--
-- workspace.Players holds exactly two folders with random names - the two teams.
-- Which folder is which is decided further down by the leaderboard; here we only
-- read what is there.

local function playersRoot()
	return workspace:FindFirstChild("Players")
end

-- The name and the head come out of the same object. Cached per MODEL with weak
-- keys, which is the only cache shape that survives header (3): a model that has
-- been rebuilt drops out of the table by itself instead of pinning a dead rig.
local infoCache = setmetatable({}, { __mode = "k" })

local function modelInfo(model)
	local hit = infoCache[model]
	if hit ~= nil then
		-- the head part can be destroyed while the model lives on
		if hit.head and hit.head.Parent then return hit end
		infoCache[model] = nil
	end

	local tag = model:FindFirstChild("NameTagGui", true)
	if not tag then return nil end
	local label = tag:FindFirstChild("PlayerTag")
	local head  = tag.Parent
	if not label or not head or not head:IsA("BasePart") then return nil end
	local name = label.Text
	if type(name) ~= "string" or name == "" then return nil end

	-- The six parts sorted top down. The tag holder IS the head (verified), the
	-- lowest is a foot, and that pair is all the box needs.
	local parts = {}
	for _, p in ipairs(model:GetChildren()) do
		if p:IsA("BasePart") then parts[#parts + 1] = p end
	end
	table.sort(parts, function(a, b) return a.Position.Y > b.Position.Y end)

	local set = { head = head, parts = parts, name = name, tag = tag }
	infoCache[model] = set
	return set
end

-- Health when the game publishes it, nil when it does not. See header (5) - the
-- Health frame comes and goes, and inventing a number for the bar would be the
-- panel lying about what it knows.
local function healthOf(info)
	local hf = info.tag and info.tag:FindFirstChild("Health")
	local pc = hf and hf:FindFirstChild("Percent")
	if not pc then return nil end
	local frac = pc.Size.X.Scale
	if type(frac) ~= "number" or frac ~= frac then return nil end
	return math.clamp(frac, 0, 1)
end

-- The lowest part of the rig, for the bottom of the box. Feet are not named, so
-- it is whichever of the six sits lowest THIS frame - which follows a crouch and
-- a prone exactly, for free.
local function footOf(info)
	local parts = info.parts
	if not parts or #parts == 0 then return nil end
	local low = parts[1]
	for _, p in ipairs(parts) do
		if p.Parent and p.Position.Y < low.Position.Y then low = p end
	end
	return low
end

--------------------------------------------------------------------------------
-- which folder is my team: the leaderboard says so, in plain text
--------------------------------------------------------------------------------
--
-- Player.Team is nil and the Teams service is empty, so the team cannot be read
-- off the Player object at all. What the game does still have to do is show the
-- human a scoreboard, and that scoreboard is ordinary GUI:
--
--   LeaderboardScreenGui.DisplayScoreFrame.Container
--     DisplayPhantomBoard.DisplayTeamBar.TextTeam   -> "PHANTOMS"
--     DisplayPhantomBoard.Container.DisplayPlayerScore.TextPlayer -> a name
--     DisplayGhostBoard   ... the same for "GHOSTS"
--
-- So: name -> board for everyone including us, then folder -> board by majority
-- vote of the names inside it. The vote matters because a model can be mid-swap
-- (header 3) and answer for nobody; one blank must not flip a whole team.
--
-- The GUI is read whether or not it is on screen - Enabled is false most of the
-- time and the labels are filled in anyway.

local boardOf   = {}          -- player name -> "PHANTOMS" / "GHOSTS"
local boardStat = {}          -- player name -> { kills, deaths, score, rank }
local folderTeam = {}         -- folder instance -> board name
local myBoard   = nil
local boardAt   = 0

local function readBoards()
	local gui = plr:FindFirstChild("PlayerGui")
	gui = gui and gui:FindFirstChild("LeaderboardScreenGui")
	local frame = gui and gui:FindFirstChild("DisplayScoreFrame")
	local root  = frame and frame:FindFirstChild("Container")
	if not root then return false, "no leaderboard gui" end

	local found = {}
	local stats = {}
	local boards = 0
	for _, board in ipairs(root:GetChildren()) do
		local bar  = board:FindFirstChild("DisplayTeamBar")
		local name = bar and bar:FindFirstChild("TextTeam")
		local list = board:FindFirstChild("Container")
		if name and list then
			boards = boards + 1
			local teamName = name.Text
			for _, row in ipairs(list:GetChildren()) do
				local who = row:FindFirstChild("TextPlayer", true)
				if who and who.Text ~= "" then
					found[who.Text] = teamName
					local function num(n)
						local l = row:FindFirstChild(n, true)
						return l and tonumber((l.Text:gsub("%s", ""))) or 0
					end
					stats[who.Text] = { kills = num("TextKills"), deaths = num("TextDeaths"),
						score = num("TextScore"), rank = num("TextRank") }
				end
			end
		end
	end
	if boards == 0 then return false, "leaderboard has no boards" end

	boardOf, boardStat = found, stats
	myBoard = found[plr.Name]
	return true, boards .. " boards, " .. (function()
		local n = 0 for _ in pairs(found) do n = n + 1 end return n
	end)() .. " players"
end

local function evaluateTeams()
	local now = os.clock()
	if now - boardAt < 1.5 then return end
	boardAt = now

	local report = {}
	local ok, why = readBoards()
	report[#report + 1] = "leaderboard: " .. (ok and why or ("FAILED - " .. why))

	local root = playersRoot()
	if not root then
		STATE.chain = report
		STATE.teamNote = "workspace.Players missing"
		return
	end

	-- folder -> team, by majority of the names inside it
	local newMap = {}
	for _, folder in ipairs(root:GetChildren()) do
		local votes, best, bestN = {}, nil, 0
		local counted = 0
		for _, model in ipairs(folder:GetChildren()) do
			local info = modelInfo(model)
			local b = info and boardOf[info.name]
			if b then
				counted = counted + 1
				votes[b] = (votes[b] or 0) + 1
				if votes[b] > bestN then best, bestN = b, votes[b] end
			end
		end
		if best then newMap[folder] = best end
		report[#report + 1] = "folder " .. folder.Name .. ": "
			.. (best and (best .. " (" .. bestN .. " of " .. counted .. ")")
				or "no name resolved yet")
	end
	folderTeam = newMap

	if myBoard then
		STATE.myTeam = myBoard
		STATE.teamNote = "leaderboard"
		report[#report + 1] = "you are " .. myBoard
	else
		-- Dead in the lobby, or the board has not filled in yet. Everyone is a
		-- target: showing too much is recoverable, going silent in the game the
		-- script exists for is not.
		STATE.myTeam = "-"
		STATE.teamNote = "no side for you - everyone is a target"
		report[#report + 1] = "you are on no board - everyone is a target"
	end
	STATE.chain = report
end

local function isTarget(folder, info)
	if info.name == plr.Name then return false end
	if CONFIG.teamMode == "Everyone" then return true end
	if not myBoard then return true end
	local team = folderTeam[folder] or boardOf[info.name]
	if not team then return true end
	local hostile = (team ~= myBoard)
	if CONFIG.teamInvert then hostile = not hostile end
	return hostile
end

--------------------------------------------------------------------------------
-- one entry per NAME, newest model wins
--------------------------------------------------------------------------------
--
-- A rebuild (header 3) leaves the dying model and its replacement in the folder
-- AT THE SAME TIME, and both carry the same PlayerTag. Read straight out of the
-- folder, both write the same Drawing set within one frame and the box jumps
-- between the stale position and the live one several times a second - which is
-- exactly the "the ESP bugs out when someone goes green" report, and the same
-- flicker made the aim assist chase a body that had stopped moving.
--
-- GetChildren is insertion order, so the LAST model carrying a name is the new
-- one. Everything downstream - ESP, aim, trigger, chams - goes through here, so
-- none of them can disagree about who is where.

local snapList, snapAt = {}, 0

local function snapshot()
	local now = os.clock()
	if now - snapAt < 0.004 then return snapList end   -- at most once per frame
	local root = playersRoot()
	local byName = {}
	if root then
		for _, folder in ipairs(root:GetChildren()) do
			for _, model in ipairs(folder:GetChildren()) do
				local info = modelInfo(model)
				if info then
					info.folder = folder
					byName[info.name] = info
				end
			end
		end
	end
	local list = {}
	for _, info in pairs(byName) do list[#list + 1] = info end
	snapList, snapAt = list, now
	return list
end

local function eachTarget(fn)
	for _, info in ipairs(snapshot()) do
		if isTarget(info.folder, info) then fn(info) end
	end
end

--------------------------------------------------------------------------------
-- churn meter
--------------------------------------------------------------------------------
--
-- Header (3) is the single most surprising thing about this game, so the panel
-- measures it live rather than quoting the session it was found in. It is also a
-- health check: if this drops to zero the replication has stopped and the ESP is
-- drawing a frozen world.

local churnCount, churnAt, churnHooked = 0, os.clock(), {}

local function hookChurn()
	local root = playersRoot()
	if not root then return end
	for _, folder in ipairs(root:GetChildren()) do
		if not churnHooked[folder] then
			churnHooked[folder] = true
			folder.ChildAdded:Connect(function()
				if _G.__SELPF == GEN then churnCount = churnCount + 1 end
			end)
		end
	end
end

--------------------------------------------------------------------------------
-- line of sight
--------------------------------------------------------------------------------
--
-- Measured on this map: 10035 parts, of which 108 are fully transparent AND not
-- collidable (effect ghosts) and 368 are transparent but collidable (real
-- invisible walls). Only the first group is excluded - the Arsenal property
-- test - because an invisible wall still stops a bullet here, and there is no
-- clip-brush layer like Counter Blox's 210 CLIP parts. Six sample rays to enemy
-- heads all stopped on opaque collidable geometry, so nothing needed a special
-- case.

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true

local filterAt = 0
local ghosts = {}
local ghostAt = 0
local ghostMap = nil

local function rescanGhosts()
	local map = workspace:FindFirstChild("Map")
	if not map then return end
	-- Only when the map model itself was replaced: the scan is ~19 ms over 11k
	-- descendants, which is fine on a timer and not fine per frame.
	if map == ghostMap and os.clock() - ghostAt < 30 then return end
	ghostMap, ghostAt = map, os.clock()
	local list = {}
	for _, p in ipairs(map:GetDescendants()) do
		if p:IsA("BasePart") and p.Transparency >= 1 and not p.CanCollide then
			list[#list + 1] = p
		end
	end
	ghosts = list
end

local function refreshFilter()
	local now = os.clock()
	if now - filterAt < 1 then return end
	filterAt = now
	rescanGhosts()

	local list = {}
	local root = playersRoot()
	if root then list[#list + 1] = root end          -- every body, ours included
	-- The VIEWMODEL. workspace.Camera carries three Models of 21, 9 and 14 parts -
	-- our own arms and gun, a few studs in front of the ray origin. A bullet does
	-- not stop on your own weapon, and leaving them in marks every enemy blocked.
	if camera then list[#list + 1] = camera end
	for _, name in ipairs({ "Ignore", "Effects", "Debris", "Roots" }) do
		local f = workspace:FindFirstChild(name)
		if f then list[#list + 1] = f end
	end
	for _, p in ipairs(ghosts) do list[#list + 1] = p end
	rayParams.FilterDescendantsInstances = list
end

local function visible(worldPos)
	local origin = camera.CFrame.Position
	return workspace:Raycast(origin, worldPos - origin, rayParams) == nil
end

--------------------------------------------------------------------------------
-- drawing
--------------------------------------------------------------------------------
--
-- Keyed by PLAYER NAME, not by model and not by Player object: the models are
-- rebuilt every few seconds (header 3) and a model-keyed pool would allocate a
-- fresh set of Drawings several times a second per player.

local drawn, pool = {}, {}

-- Last run's objects are still on screen after a re-execute with nothing driving
-- them. The generation guard stops the LOOP; only this clears the PIXELS.
if _G.__SELPF_POOL then
	for _, obj in ipairs(_G.__SELPF_POOL) do pcall(function() obj:Remove() end) end
end
_G.__SELPF_POOL = pool

local function make(kind, props)
	if not HAS_DRAWING then return nil end
	local ok, obj = pcall(function() return Drawing.new(kind) end)
	if not ok or not obj then return nil end
	obj.Visible = false
	for k, v in pairs(props or {}) do pcall(function() obj[k] = v end) end
	pool[#pool + 1] = obj
	return obj
end

local function objectsFor(name)
	local set = drawn[name]
	if set then
		set.seen = os.clock()
		return set
	end
	set = {
		outline = make("Square", { Thickness = 3, Filled = false, ZIndex = 1,
			Color = Color3.new(0, 0, 0), Transparency = 0.6 }),
		box     = make("Square", { Thickness = 1, Filled = false, ZIndex = 2 }),
		fill    = make("Square", { Filled = true, ZIndex = 0, Transparency = 0.15 }),
		hpBg    = make("Square", { Filled = true, ZIndex = 1, Color = Color3.new(0, 0, 0),
			Transparency = 0.6 }),
		hp      = make("Square", { Filled = true, ZIndex = 2 }),
		name    = make("Text", { Size = 13, Center = true, Outline = true, ZIndex = 3 }),
		info    = make("Text", { Size = 12, Center = true, Outline = true, ZIndex = 3 }),
		tracer  = make("Line", { Thickness = 1, ZIndex = 1 }),
		head    = make("Circle", { Thickness = 1, Filled = false, NumSides = 14, ZIndex = 3 }),
		bones   = {},
		seen    = os.clock(),
	}
	-- five bones: head down the spine to the lowest part, and the four others
	-- hung off it. The rig has no named limbs, so the skeleton is drawn from the
	-- six points as they sort, which is honest about what is actually known.
	for i = 1, 5 do
		set.bones[i] = make("Line", { Thickness = 1, ZIndex = 2 })
	end
	drawn[name] = set
	return set
end

-- The set is walked by KEY, never by type. A Drawing is userdata in Potassium,
-- not a table, so an "is it a table" guard here silently hid nothing at all -
-- and the symptom is the one that got reported: boxes from a finished match
-- still on screen next to the live ones, because the only thing that ever
-- cleared them was never running.
local DRAW_KEYS = { "outline", "box", "fill", "hpBg", "hp", "name", "info",
	"tracer", "head" }

local function hideSet(set)
	for _, k in ipairs(DRAW_KEYS) do
		local obj = set[k]
		if obj then pcall(function() obj.Visible = false end) end
	end
	if set.bones then
		for _, b in ipairs(set.bones) do
			if b then pcall(function() b.Visible = false end) end
		end
	end
end

local function removeSet(set)
	for _, k in ipairs(DRAW_KEYS) do
		local obj = set[k]
		if obj then pcall(function() obj:Remove() end) end
	end
	if set.bones then
		for _, b in ipairs(set.bones) do
			if b then pcall(function() b:Remove() end) end
		end
	end
end

local function hideAll()
	for _, set in pairs(drawn) do hideSet(set) end
end

local fovCircle = make("Circle", { Thickness = 1, NumSides = 48, Filled = false,
	Transparency = 0.5, ZIndex = 1 })

-- A second ring for the silent aim, because the two FOVs are different numbers
-- and a page whose radius cannot be seen is a page tuned by guesswork.
local silCircle = make("Circle", { Thickness = 1, NumSides = 48, Filled = false,
	Transparency = 0.5, ZIndex = 1 })

--------------------------------------------------------------------------------
-- chams
--------------------------------------------------------------------------------
--
-- A Highlight has to be a real Instance, so the only question is where it lives.
-- Parented into the character it sits in the Workspace where any client script
-- can walk onto it; parented to gethui() with Adornee set it renders identically
-- and is not in the game's tree at all.
--
-- The PF twist: the model it is adorned to is destroyed and rebuilt several
-- times a second (header 3), so the Adornee is re-pointed every frame from the
-- deduped snapshot. A Highlight whose Adornee was destroyed simply draws
-- nothing, which is why this looked like "chams that fade out after a second"
-- on the first build.

local chamsHost = nil
pcall(function()
	chamsHost = (getHui and getHui()) or game:GetService("CoreGui")
end)

local chams = {}

if _G.__SELPF_CHAMS then
	for _, h in pairs(_G.__SELPF_CHAMS) do pcall(function() h:Destroy() end) end
end
_G.__SELPF_CHAMS = chams

local function chamFor(name)
	local h = chams[name]
	if h and h.Parent then return h end
	if not chamsHost then return nil end
	local ok, made = pcall(function()
		local x = Instance.new("Highlight")
		x.Name = "SeluxPF"
		x.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		x.Enabled = false
		x.Parent = chamsHost
		return x
	end)
	if not ok then return nil end
	chams[name] = made
	return made
end

local function hideCham(name)
	local h = chams[name]
	if h then pcall(function() h.Enabled = false h.Adornee = nil end) end
end

local function hideAllChams()
	for name in pairs(chams) do hideCham(name) end
end

--------------------------------------------------------------------------------
-- the box
--------------------------------------------------------------------------------
--
-- Head down to the lowest part, both projected. The projected distance between
-- them IS the on-screen height, so it scales with range for free and follows a
-- crouch exactly. Model:GetBoundingBox() is never called - see traps.md, and in
-- this game it would be measuring six 0.001-stud anchors anyway.

local function screenBox(info)
	local head = info.head
	local foot = footOf(info)
	if not head or not foot or not head.Parent then return nil end

	-- the anchors are 0.001 studs, so the visible head sits about 0.9 studs above
	-- the head anchor and the soles about 0.1 below the lowest one
	local top = head.Position + Vector3.new(0, 0.9, 0)
	local bot = foot.Position - Vector3.new(0, 0.1, 0)

	local sTop = camera:WorldToViewportPoint(top)
	local sBot = camera:WorldToViewportPoint(bot)
	-- Z <= 0 is BEHIND the camera; the X/Y reported there is mirrored nonsense
	if sTop.Z <= 0 or sBot.Z <= 0 then return nil end

	local h = math.abs(sBot.Y - sTop.Y)
	if h < 1 then return nil end
	local w = h * 0.52
	local cx = (sTop.X + sBot.X) / 2
	return cx - w / 2, math.min(sTop.Y, sBot.Y), w, h
end

--------------------------------------------------------------------------------
-- the render pass
--------------------------------------------------------------------------------

local function centre()
	local vp = camera.ViewportSize
	return Vector2.new(vp.X / 2, vp.Y / 2)
end

local function renderPass()
	if _G.__SELPF ~= GEN then return end
	refreshFilter()
	evaluateTeams()
	hookChurn()

	local now = os.clock()
	if now - churnAt >= 1 then
		STATE.churn = math.floor(churnCount / (now - churnAt) + 0.5)
		churnCount, churnAt = 0, now
	end

	local mid = centre()
	if fovCircle then
		fovCircle.Visible = CONFIG.aim and CONFIG.aimCircle
		if fovCircle.Visible then
			fovCircle.Position = mid
			fovCircle.Radius = CONFIG.aimFov
			fovCircle.Color = CONFIG.colFov
		end
	end
	if silCircle then
		silCircle.Visible = CONFIG.silent and CONFIG.silentCircle
		if silCircle.Visible then
			silCircle.Position = mid
			silCircle.Radius = CONFIG.silentFov
			silCircle.Color = CONFIG.colSilentFov
		end
	end

	if not CONFIG.esp or not HAS_DRAWING then
		hideAll()
		hideAllChams()
		STATE.targets = 0
		return
	end

	local camPos = camera.CFrame.Position
	local root = playersRoot()
	local seen, live = 0, 0
	local shownNames = {}

	if root then
		-- snapshot() is the deduped list: one entry per name, newest model wins.
		-- Reading the folders directly here is what made the box flicker.
		for _, info in ipairs(snapshot()) do
			if info.head.Parent then
					live = live + 1
					if isTarget(info.folder, info) then
						local set = objectsFor(info.name)
						local dist = (camPos - info.head.Position).Magnitude
						if dist <= CONFIG.maxDist then
							local vis = visible(info.head.Position)
							if vis or not CONFIG.espVisOnly then
								local x, y, w, h = screenBox(info)
								if x then
									seen = seen + 1
									shownNames[info.name] = true
									local col = vis and CONFIG.colVisible or CONFIG.colEnemy
									local alpha = (vis or not CONFIG.espDimHidden) and 1 or 0.45
									local txt = math.max(12, math.floor(CONFIG.espTextSize))

									if CONFIG.chams then
										local h = chamFor(info.name)
										if h then
											-- re-pointed every frame, because the
											-- model under it is not the same one
											-- it was a second ago
											h.Adornee = info.head.Parent
											h.FillColor = col
											h.OutlineColor = col
											h.FillTransparency = 1 - CONFIG.chamsFill
											h.OutlineTransparency = CONFIG.chamsOutline
											h.Enabled = true
										end
									else
										hideCham(info.name)
									end

									if CONFIG.espBox then
										set.outline.Position = Vector2.new(x, y)
										set.outline.Size = Vector2.new(w, h)
										set.outline.Transparency = 0.6 * alpha
										set.outline.Visible = true
										set.box.Position = Vector2.new(x, y)
										set.box.Size = Vector2.new(w, h)
										set.box.Color = col
										set.box.Transparency = alpha
										set.box.Visible = true
									end
									if CONFIG.espBoxFill then
										set.fill.Position = Vector2.new(x, y)
										set.fill.Size = Vector2.new(w, h)
										set.fill.Color = col
										set.fill.Transparency = 0.15 * alpha
										set.fill.Visible = true
									end
									if CONFIG.espHealth then
										local frac = healthOf(info)
										if frac then
											set.hpBg.Position = Vector2.new(x - 6, y)
											set.hpBg.Size = Vector2.new(3, h)
											set.hpBg.Visible = true
											set.hp.Position = Vector2.new(x - 6, y + h * (1 - frac))
											set.hp.Size = Vector2.new(3, h * frac)
											set.hp.Color = Color3.fromRGB(255, 70, 70)
												:Lerp(Color3.fromRGB(90, 235, 110), frac)
											set.hp.Visible = true
										end
									end
									if CONFIG.espName then
										set.name.Text = info.name
										set.name.Size = txt
										set.name.Font = CONFIG.espFont
										set.name.Position = Vector2.new(x + w / 2, y - txt - 2)
										set.name.Color = CONFIG.colText
										set.name.Transparency = alpha
										set.name.Visible = true
									end
									if CONFIG.espInfo or CONFIG.espScore then
										local line = ""
										if CONFIG.espInfo then
											line = math.floor(dist) .. "m"
										end
										if CONFIG.espScore then
											local st = boardStat[info.name]
											if st then
												line = line .. (line ~= "" and "  " or "")
													.. st.kills .. "/" .. st.deaths
											end
										end
										set.info.Text = line
										set.info.Size = math.max(12, txt - 1)
										set.info.Font = CONFIG.espFont
										set.info.Position = Vector2.new(x + w / 2, y + h + 1)
										set.info.Color = CONFIG.colText
										set.info.Transparency = alpha
										set.info.Visible = true
									end
									if CONFIG.espTracer then
										set.tracer.From = Vector2.new(mid.X, camera.ViewportSize.Y)
										set.tracer.To = Vector2.new(x + w / 2, y + h)
										set.tracer.Color = col
										set.tracer.Transparency = alpha
										set.tracer.Visible = true
									end
									if CONFIG.espHeadDot then
										local sp = camera:WorldToViewportPoint(info.head.Position)
										if sp.Z > 0 then
											set.head.Position = Vector2.new(sp.X, sp.Y)
											set.head.Radius = math.max(2, h * 0.075)
											set.head.Color = col
											set.head.Transparency = alpha
											set.head.Visible = true
										end
									end
									if CONFIG.espSkeleton and #info.parts >= 2 then
										local pts = {}
										for i, p in ipairs(info.parts) do
											if p.Parent then
												local sp = camera:WorldToViewportPoint(p.Position)
												pts[i] = (sp.Z > 0)
													and Vector2.new(sp.X, sp.Y) or nil
											end
										end
										for i = 1, 5 do
											local b = set.bones[i]
											if b and pts[1] and pts[i + 1] then
												b.From = pts[1]
												b.To = pts[i + 1]
												b.Color = col
												b.Transparency = alpha
												b.Visible = true
											elseif b then
												b.Visible = false
											end
										end
									end
								end
							end
						end
					end
			end
		end
	end

	-- Hide whatever did not draw this frame, and retire a name nobody has used
	-- for half a minute so a long session does not keep a set per player who left.
	for name, set in pairs(drawn) do
		if not shownNames[name] then
			hideSet(set)
			hideCham(name)
			if now - (set.seen or now) > 30 then
				removeSet(set)
				local h = chams[name]
				if h then pcall(function() h:Destroy() end) chams[name] = nil end
				drawn[name] = nil
			end
		else
			set.seen = now
		end
	end

	STATE.targets = seen
	STATE.alive = live
end

--------------------------------------------------------------------------------
-- input: keys, and which click actually arrives
--------------------------------------------------------------------------------

local function keyFromName(name)
	if type(name) ~= "string" then return nil end
	-- Indexing an Enum with a name it does not have THROWS instead of returning
	-- nil, so both lookups are wrapped.
	local ok, k = pcall(function()
		if name:sub(1, 11) == "MouseButton" then return Enum.UserInputType[name] end
		return Enum.KeyCode[name]
	end)
	return ok and k or nil
end

local function hotkeyHeld(name)
	local k = keyFromName(name)
	if not k then return false end
	local ok, held = pcall(function()
		if typeof(k) == "EnumItem" and k.EnumType == Enum.UserInputType then
			return UserInputService:IsMouseButtonPressed(k)
		end
		return UserInputService:IsKeyDown(k)
	end)
	return ok and held or false
end

local function firing()
	return UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1)
end

-- Probed, never assumed. Measured in Potassium: keypress exists and delivers
-- NOTHING, and a trigger built on "prefer whatever is present" then counts shots
-- it never fired. The probe sends one click through each transport in turn and
-- asks UserInputService which one arrived.
local clickFn = nil

local function probeClick()
	-- COUNT BULLETS, NOT INPUTS. The obvious probe watches
	-- UserInputService.InputBegan, and in this game it picks a transport that
	-- shoots nothing: three `mouse1click` calls arrived at InputBegan and
	-- produced **0** bullets, while three VirtualInputManager pairs produced 3.
	-- A trigger built on the input count then reports shots it never fired.
	--
	-- The server echoes our own bullets back in `newbullets`, so that is the
	-- oracle. It costs a few real rounds, which is why it waits until there is a
	-- gun to fire.
	-- Both of these are resolved inline rather than through the file's own
	-- helpers: this function sits ABOVE them, and a Lua local is invisible above
	-- its own definition - the reference would silently find a nil global.
	local fired = 0
	local ev = game:GetService("ReplicatedStorage"):FindFirstChild("RemoteEvent")
	local conn = ev and ev.OnClientEvent:Connect(function(cmd, a)
		if cmd == "newbullets" and type(a) == "table" and a.player == plr then
			fired = fired + 1
		end
	end)

	local function ownHealth()
		local gui = plr:FindFirstChild("PlayerGui")
		gui = gui and gui:FindFirstChild("HudScreenGui")
		local main = gui and gui:FindFirstChild("Main")
		local st = main and main:FindFirstChild("DisplayStatus")
		local l = st and st:FindFirstChild("TextHealth", true)
		return l and tonumber(l.Text) or 0
	end

	local waited = 0
	while waited < 60 and ownHealth() <= 0 do
		task.wait(1)
		waited = waited + 1
	end

	local function try(label, fn)
		if clickFn then return end
		if not fn then return end
		local before = fired
		pcall(fn)
		task.wait(0.45)
		if fired > before then
			clickFn = fn
			STATE.clickWay = label
		end
	end

	local viaVIM = VIM and function()
		local m = UserInputService:GetMouseLocation()
		VIM:SendMouseButtonEvent(m.X, m.Y, 0, true, game, 0)
		task.wait(0.04)
		VIM:SendMouseButtonEvent(m.X, m.Y, 0, false, game, 0)
	end or nil

	try("mouse1click", clickOnce)
	try("mouse1press/release", (clickDown and clickUp) and function()
		clickDown() task.wait(0.03) clickUp()
	end or nil)
	try("VirtualInputManager", viaVIM)

	if conn then conn:Disconnect() end

	if not clickFn then
		-- Nothing produced a bullet: out of ammo, a knife in hand, or the window
		-- was not focused. Fall back to the transport that has been measured to
		-- work here rather than reporting "the trigger cannot fire", and say the
		-- reading is unverified so nobody reads it as a proven answer.
		clickFn = viaVIM
		STATE.clickWay = viaVIM and "VirtualInputManager (unverified)"
			or "NONE WORK - trigger cannot fire"
	end
end

--------------------------------------------------------------------------------
-- aim assist
--------------------------------------------------------------------------------

local function aimActive()
	if not CONFIG.aim then return false end
	if CONFIG.hum and CONFIG.humPanelOff and STATE.panelOpen then return false end
	if CONFIG.aimActive == "Always" then return true end
	if CONFIG.aimActive == "While firing" then return firing() end
	return hotkeyHeld(CONFIG.aimKey)
end

local function approach(smooth, dt)
	local base = 1 / math.max(1, smooth)
	return 1 - (1 - base) ^ math.max(dt * 60, 0.0001)
end

local function angleDelta(a, b)
	local d = (b - a) % (math.pi * 2)
	if d > math.pi then d = d - math.pi * 2 end
	return d
end

local noiseX, noiseY, noiseTX, noiseTY, noiseAt = 0, 0, 0, 0, 0

-- A smooth random walk, not per-frame randomness: white noise on a camera reads
-- as a stutter, a walk reads as a hand.
local function noiseStep(dt)
	if not CONFIG.hum or CONFIG.humNoise <= 0 then
		noiseX, noiseY = 0, 0
		return 0, 0
	end
	local now = os.clock()
	local period = 1 / math.max(0.1, CONFIG.humNoiseHz)
	if now - noiseAt > period then
		noiseAt = now
		noiseTX, noiseTY = math.random() * 2 - 1, math.random() * 2 - 1
	end
	local k = math.clamp(dt / period, 0, 1) * 2
	noiseX = noiseX + (noiseTX - noiseX) * k
	noiseY = noiseY + (noiseTY - noiseY) * k
	local amp = math.rad(CONFIG.humNoise)
	return noiseX * amp, noiseY * amp
end

--------------------------------------------------------------------------------
-- ballistics: this game's bullets travel and they fall
--------------------------------------------------------------------------------
--
-- Read straight off a captured `newbullets` payload: every bullet carries
-- `acceleration = (0, -196.2, 0)` and a velocity whose magnitude is the weapon's
-- `bulletspeed` - 2950 for the AN-94, 2800 for the HOWA TYPE 20 and the WA2000,
-- 1400 for the HARDBALLER. At 300 studs a 2800 stud/s bullet is in the air for
-- 0.107 s and has dropped 1.1 studs, which is most of a head; at 600 it is 4.5
-- studs and the shot goes under the feet. An assist that aims at the head
-- position therefore misses at exactly the ranges where an assist is worth
-- having.
--
-- The whole stat block is readable from the MAIN VM: the weapon folders under
-- ReplicatedStorage.Content.ProductionContent.WeaponDatabase each hold a
-- ModuleScript, and requiring it from here returns a private copy - useless for
-- changing anything, perfect for reading 95 static numbers.
--
-- WHICH weapon is held is not stored anywhere readable, so it is identified by
-- its FIRE RATE: the HUD prints it ("[580 S]"), the loadout arrives in the
-- `newspawn` payload, and the entry whose `firerate` matches is the one in our
-- hands. No slot-index mapping to guess and nothing to keep in sync when the
-- game reorders its inventory.

local RS = game:GetService("ReplicatedStorage")

local GRAVITY = 196.2
pcall(function()
	for _, m in ipairs(getloadedmodules()) do
		if m.Name == "PublicSettings" then
			local ok, t = pcall(require, m)
			if ok and type(t) == "table" and typeof(t.bulletAcceleration) == "Vector3" then
				GRAVITY = math.abs(t.bulletAcceleration.Y)
			end
			break
		end
	end
end)

local statCache = {}

local function weaponStats(name)
	if name == nil or name == "" then return nil end
	if statCache[name] ~= nil then return statCache[name] or nil end
	local db = RS:FindFirstChild("Content")
	db = db and db:FindFirstChild("ProductionContent")
	db = db and db:FindFirstChild("WeaponDatabase")
	if not db then statCache[name] = false return nil end
	for _, cat in ipairs(db:GetChildren()) do
		local gun = cat:FindFirstChild(name)
		if gun then
			for _, k in ipairs(gun:GetChildren()) do
				if k:IsA("ModuleScript") then
					local ok, res = pcall(require, k)
					if ok and type(res) == "table" then
						statCache[name] = res
						return res
					end
				end
			end
		end
	end
	statCache[name] = false
	return nil
end

local myLoadout = {}          -- filled from our own newspawn

local function hudRpm()
	local gui = plr:FindFirstChild("PlayerGui")
	gui = gui and gui:FindFirstChild("HudScreenGui")
	local main = gui and gui:FindFirstChild("Main")
	local st = main and main:FindFirstChild("DisplayStatus")
	local l = st and st:FindFirstChild("TextFiremode", true)
	if not l then return nil end
	return tonumber(l.Text:gsub("<[^>]->", ""):match("(%d+)"))
end

-- The largest magazine count seen since the fire rate last changed: that IS the
-- capacity, and it is the second half of the weapon's fingerprint.
local maxMagSeen, magForRpm = 0, nil

local function trackMag()
	local gui = plr:FindFirstChild("PlayerGui")
	gui = gui and gui:FindFirstChild("HudScreenGui")
	local main = gui and gui:FindFirstChild("Main")
	local st = main and main:FindFirstChild("DisplayStatus")
	local l = st and st:FindFirstChild("TextMagCount", true)
	local n = l and tonumber(l.Text)
	if not n then return end
	local rpm = hudRpm()
	if rpm ~= magForRpm then
		magForRpm, maxMagSeen = rpm, 0
	end
	if n > maxMagSeen then maxMagSeen = n end
end

local function firerateOf(stats)
	local fr = stats and stats.firerate
	if type(fr) == "number" then return fr end
	if type(fr) == "table" then
		for _, v in pairs(fr) do if type(v) == "number" then return v end end
	end
	return nil
end

-- The loadout only arrives on a RESPAWN, so on the first run the weapon is
-- unknown until the player next dies - and a drop compensation that waits for
-- that is a drop compensation nobody ever sees working. The whole database is
-- therefore indexed by fire rate in the background, which makes the HUD's own
-- "[750 A]" enough to identify the gun on its own. Chunked with a yield every
-- 25 modules: requiring ~400 of them in one frame is a visible hitch.
local rpmIndex = nil
local rpmIndexed = 0

task.spawn(function()
	local db = RS:FindFirstChild("Content")
	db = db and db:FindFirstChild("ProductionContent")
	db = db and db:FindFirstChild("WeaponDatabase")
	if not db then return end
	local idx, n = {}, 0
	for _, cat in ipairs(db:GetChildren()) do
		for _, gun in ipairs(cat:GetChildren()) do
			if _G.__SELPF ~= GEN then return end
			for _, k in ipairs(gun:GetChildren()) do
				if k:IsA("ModuleScript") then
					local ok, res = pcall(require, k)
					if ok and type(res) == "table" and res.bulletspeed then
						local fr = firerateOf(res)
						if fr then
							idx[fr] = idx[fr] or {}
							table.insert(idx[fr], { name = gun.Name, stats = res })
						end
					end
					n = n + 1
					if n % 25 == 0 then task.wait() end
				end
			end
		end
	end
	rpmIndex, rpmIndexed = idx, n
end)

-- The held weapon: the loadout first, because that is only four candidates and
-- cannot be ambiguous, then the whole index.
local heldName, heldStats, heldAt = "-", nil, 0

local function heldWeapon()
	local now = os.clock()
	trackMag()
	if now - heldAt < 0.5 then return heldName, heldStats end
	heldAt = now
	local rpm = hudRpm()
	local function near(fr) return rpm and fr and math.abs(fr - rpm) <= math.max(2, rpm * 0.03) end

	local bestName, bestStats
	for _, name in pairs(myLoadout) do
		local st = weaponStats(name)
		if st and near(firerateOf(st)) then bestName, bestStats = name, st break end
		if st and not bestStats then bestName, bestStats = name, st end
	end

	if not (bestStats and near(firerateOf(bestStats))) and rpmIndex and rpm then
		local hit = rpmIndex[rpm]
		if not hit then
			-- the HUD rounds, so take the closest rate in the index
			local bestDiff
			for fr, list in pairs(rpmIndex) do
				local diff = math.abs(fr - rpm)
				if not bestDiff or diff < bestDiff then bestDiff, hit = diff, list end
			end
			if bestDiff and bestDiff > math.max(2, rpm * 0.03) then hit = nil end
		end
		if hit and hit[1] then
			-- Ten weapons share 750 rounds a minute, so the rate alone is not an
			-- identification. The MAGAZINE is the second key: the HUD prints the
			-- rounds left, the highest value seen since the gun was picked up is
			-- its capacity, and that pair is almost always unique.
			local list = hit
			if maxMagSeen and maxMagSeen > 0 then
				local filtered = {}
				for _, c in ipairs(hit) do
					if tonumber(c.stats.magsize) == maxMagSeen then
						filtered[#filtered + 1] = c
					end
				end
				if #filtered > 0 then list = filtered end
			end
			-- Where several still qualify, say so rather than picking silently:
			-- what matters downstream is the bullet speed, and if they agree on
			-- that the ambiguity costs nothing.
			local sameSpeed = true
			for _, c in ipairs(list) do
				if c.stats.bulletspeed ~= list[1].stats.bulletspeed then sameSpeed = false break end
			end
			bestName = list[1].name
			if #list > 1 then
				bestName = bestName .. (sameSpeed and (" (+" .. (#list - 1) .. ", same speed)")
					or (" (+" .. (#list - 1) .. " unsure)"))
			end
			bestStats = list[1].stats
		end
	end

	heldName = bestName or "-"
	heldStats = bestStats
	return heldName, heldStats
end

-- Where to aim so the bullet ARRIVES at the target, rather than where the target
-- is now. Two iterations is plenty: the flight time changes the lead, the lead
-- barely changes the flight time.
local velTrack = {}           -- name -> { pos, t, vel }

local function trackVelocity(name, pos)
	local now = os.clock()
	local e = velTrack[name]
	if not e then
		velTrack[name] = { pos = pos, t = now, vel = Vector3.zero }
		return Vector3.zero
	end
	local dt = now - e.t
	if dt > 0.015 then
		local step = (pos - e.pos).Magnitude
		local raw = (pos - e.pos) / dt
		-- The models here are destroyed and rebuilt several times a second, so
		-- two samples under the same NAME can belong to different instances and
		-- the difference between them is a teleport, not movement. Two gates:
		-- the sample must be recent, and the step must be small enough that a
		-- human could have walked it. Without them a single jump became a 45
		-- stud lead on a 0.38 s flight and the bullet left the map.
		if dt < 0.5 and step < 12 and raw.Magnitude < 60 then
			e.vel = e.vel * 0.7 + raw * 0.3
		elseif step >= 12 then
			e.vel = Vector3.zero          -- a jump means we know nothing again
		end
		e.pos, e.t = pos, now
	end
	return e.vel
end

-- The bullet speed does not have to be looked up at all: the server echoes our
-- OWN bullets back to us in `newbullets`, and the payload carries the real
-- velocity and acceleration. Measured on a live round: 22 of our own shots came
-- back reading exactly 2800.0 studs/s and -196.2. A measured constant beats a
-- database entry chosen from ten weapons that share a fire rate, so the lookup
-- is only the seed until the first shot is fired.
local measuredSpeed, measuredGravity = 0, nil

local function predictPoint(part, name)
	local pos = part.Position
	if not CONFIG.aimPredict then return pos end
	local speed = measuredSpeed
	if speed <= 0 then
		local _, stats = heldWeapon()
		speed = stats and tonumber(stats.bulletspeed) or 0
	end
	if speed <= 0 then return pos end
	local g = measuredGravity or GRAVITY

	local origin = camera.CFrame.Position
	local vel = CONFIG.aimLead and trackVelocity(name, pos) or Vector3.zero
	local aim = pos
	for _ = 1, 2 do
		local t = (aim - origin).Magnitude / speed
		aim = pos + vel * t + Vector3.new(0, g * t * t / 2, 0)
	end
	STATE.dropStuds = aim.Y - pos.Y
	return aim
end

--------------------------------------------------------------------------------
-- recoil control that measures itself
--------------------------------------------------------------------------------
--
-- No pattern table is read and none is needed. Every frame the camera's own
-- pitch/yaw change is compared against the RAW mouse movement the player made in
-- that same frame:
--
--   while NOT firing, the ratio of the two IS the effective sensitivity, and it
--   is averaged continuously - which also survives this game's per-weapon zoom
--   multiplier, because the estimate simply follows it
--   while firing, whatever pitch change is left after subtracting
--   sensitivity x mouseDelta is not the player. That residual is the recoil.
--
-- The correction goes out through mousemoverel, not through the camera: a CFrame
-- write is thrown away here within a frame (header 6), so a camera-side RCS in
-- this game would do nothing at all.
--
-- The aim point measurement that goes with it: the head ANCHOR is exactly the
-- centre of the visible head mesh (distance 0.00 on three players, mesh
-- 1.61 x 1.93 x 1.61), so nothing is offset on top of it.

local rawDX, rawDY = 0, 0

UserInputService.InputChanged:Connect(function(i)
	if _G.__SELPF ~= GEN then return end
	if i.UserInputType == Enum.UserInputType.MouseMovement then
		rawDX = rawDX + i.Delta.X
		rawDY = rawDY + i.Delta.Y
	end
end)

local lastPitch, lastYaw = nil, nil
local sensY, sensP = 0, 0
local scriptWroteMouse = false

local function rcsPass(pitchNow, yawNow)
	local dx, dy = rawDX, rawDY
	rawDX, rawDY = 0, 0

	if lastPitch == nil then
		lastPitch, lastYaw = pitchNow, yawNow
		return
	end
	local dYaw   = angleDelta(lastYaw, yawNow)
	local dPitch = pitchNow - lastPitch
	lastPitch, lastYaw = pitchNow, yawNow

	local shooting = firing()

	-- Learn only on frames the script did not write itself, or the estimate
	-- learns from our own correction and runs away.
	if not shooting and not scriptWroteMouse then
		if math.abs(dx) >= 2 then
			local s = -dYaw / dx
			if s == s and s > 0 and s < 0.1 then
				sensY = (sensY == 0) and s or (sensY * 0.9 + s * 0.1)
			end
		end
		if math.abs(dy) >= 2 then
			local s = -dPitch / dy
			if s == s and s > 0 and s < 0.1 then
				sensP = (sensP == 0) and s or (sensP * 0.9 + s * 0.1)
			end
		end
	end
	scriptWroteMouse = false
	STATE.rcsSens = sensP

	if not CONFIG.rcs or not moveMouse or sensP == 0 or not shooting then
		STATE.rcsKick = 0
		return
	end

	local residual = dPitch + sensP * dy
	STATE.rcsKick = math.deg(residual)
	-- Only an UPWARD kick is taken back. Pulling the view up when the recoil
	-- happens to settle downwards is not compensation, it is a second recoil.
	if residual <= 0 then return end

	local take = math.clamp(residual * CONFIG.rcsPct / 100, 0,
		math.rad(math.max(0.1, CONFIG.rcsMaxDeg)))
	local move = take / sensP
	if math.abs(move) >= 1 then
		scriptWroteMouse = true
		pcall(function() moveMouse(0, math.floor(move + 0.5)) end)
	end
end

-- The aim point. There is no separate hitbox rig in this game - the six anchors
-- ARE what replicates - so Head is the tag holder and Torso is the part below it.
local function aimPointOf(info)
	if CONFIG.aimPart == "Torso" then
		return info.parts[2] or info.head
	end
	if CONFIG.aimPart == "Nearest" then
		local mid = centre()
		local best, bestD
		for _, p in ipairs({ info.head, info.parts[2] }) do
			if p and p.Parent then
				local sp = camera:WorldToViewportPoint(p.Position)
				if sp.Z > 0 then
					local d = (Vector2.new(sp.X, sp.Y) - mid).Magnitude
					if not bestD or d < bestD then best, bestD = p, d end
				end
			end
		end
		return best or info.head
	end
	return info.head
end

local function pickTarget()
	local mid = centre()
	local camPos = camera.CFrame.Position
	local best, bestScore

	eachTarget(function(info)
		local part = aimPointOf(info)
		if not part or not part.Parent then return end
		local dist = (camPos - info.head.Position).Magnitude
		if dist > CONFIG.aimMaxDist then return end
		local sp = camera:WorldToViewportPoint(part.Position)
		if sp.Z <= 0 then return end
		local px = (Vector2.new(sp.X, sp.Y) - mid).Magnitude
		if px > CONFIG.aimFov then return end
		if CONFIG.aimVisible and not visible(part.Position) then return end
		local score = px
		if CONFIG.aimPick == "Closest" then score = dist end
		if not bestScore or score < bestScore then
			best, bestScore = { name = info.name, part = part, px = px, info = info }, score
		end
	end)
	return best
end

--------------------------------------------------------------------------------
-- where a silent-aimed bullet should be sent
--------------------------------------------------------------------------------
--
-- Called from inside the newBullet hook, so it runs only when a shot is fired
-- and it sees the bullet's OWN origin and speed rather than the camera's. That
-- matters: the muzzle is not the eye, and the flight time is what decides how
-- far above the head the arc has to start.

local function ballisticAim(origin, targetPos, speed, targetVel)
	local g = measuredGravity or GRAVITY
	local aim = targetPos
	for _ = 1, 3 do
		local t = (aim - origin).Magnitude / speed
		aim = targetPos + targetVel * t + Vector3.new(0, g * t * t / 2, 0)
	end
	return aim
end

-- Published into HOOKS at the bottom of this block, so the installed hook always
-- calls the CURRENT run's picker rather than the one it captured.
silentAimPoint = function(origin, speed)
	if not CONFIG.silent or speed <= 0 then return nil end

	local mid = centre()
	local best, bestPx
	eachTarget(function(info)
		local part = (CONFIG.silentPart == "Torso") and (info.parts[2] or info.head)
			or info.head
		if not part or not part.Parent then return end
		local dist = (origin - part.Position).Magnitude
		if dist > CONFIG.silentMaxDist then return end
		local sp = camera:WorldToViewportPoint(part.Position)
		if sp.Z <= 0 then return end
		local px = (Vector2.new(sp.X, sp.Y) - mid).Magnitude
		if px > CONFIG.silentFov then return end
		-- The game itself refuses a hit on a teammate, so bending a bullet at one
		-- only throws the shot away.
		local who = Players:FindFirstChild(info.name)
		if who and tostring(who.TeamColor) == tostring(plr.TeamColor) then return end
		if CONFIG.silentVisible and not visible(part.Position) then return end
		if not bestPx or px < bestPx then best, bestPx = info, px end
	end)
	if not best then return nil end

	local part = (CONFIG.silentPart == "Torso") and (best.parts[2] or best.head)
		or best.head
	STATE.silentTarget = best.name
	HOOKS.silentTarget = best.name
	local vel = CONFIG.silentLead and trackVelocity(best.name, part.Position)
		or Vector3.zero
	return ballisticAim(origin, part.Position, speed, vel)
end

HOOKS.aimPoint = silentAimPoint

--------------------------------------------------------------------------------
-- delivery
--------------------------------------------------------------------------------
--
-- MOUSE is the default here and it is not a guess: eight camera writes of 5 deg
-- each were thrown back to the previous orientation within a frame (header 6).
-- The probe still runs, so Auto is honest if the game ever changes, and the
-- dropdown lets the CHECK page's reading be overruled.

local leftYaw = nil
local pendYaw, pendPitch = 0, 0       -- requested and not yet seen in the view
local carryX, carryY = 0, 0           -- sub-unit remainder, see the Mouse branch
local lastAimYaw, lastAimPitch = nil, nil
local stickHits, stickMiss = 0, 0
local mouseSensY, mouseSensP = 0, 0
local askedX, askedY = 0, 0
local preYaw, prePitch = nil, nil

local function deliverMode()
	if CONFIG.aimDeliver == "Mouse"  then return moveMouse and "Mouse" or "Camera" end
	if CONFIG.aimDeliver == "Camera" then return "Camera" end
	if not moveMouse then return "Camera" end
	local n = stickHits + stickMiss
	if n < 90 then return "Camera" end
	STATE.stickPct = math.floor(stickHits / n * 100)
	return (STATE.stickPct >= 50) and "Camera" or "Mouse"
end

local stickyName, lockedAt, reactUntil = nil, 0, 0
local lastNX, lastNY = 0, 0

local function aimPass(dt)
	if _G.__SELPF ~= GEN then return end
	STATE.engaged = false

	local cf = camera.CFrame
	local pitchNow, yawNow = cf:ToOrientation()

	-- Runs every frame, aim or no aim: it has to keep learning the sensitivity
	-- while the player is just walking around, or there is nothing to subtract
	-- the recoil from when the shooting starts.
	pcall(rcsPass, pitchNow, yawNow)

	-- Dead-time book-keeping: a PURE DECAY, not a subtraction of what the view
	-- did. The first version subtracted the observed angle change, which
	-- includes the player's own mouse - so moving your hand drove `pending`
	-- negative, the next frame over-requested, and the crosshair sat next to the
	-- target shaking instead of locking. A request lands within a frame or two,
	-- so letting it fade is both simpler and correct.
	pendYaw, pendPitch = pendYaw * 0.35, pendPitch * 0.35
	lastAimYaw, lastAimPitch = yawNow, pitchNow

	if leftYaw ~= nil then
		local drift = math.abs(math.deg(angleDelta(leftYaw, yawNow)))
		if drift < 0.12 then stickHits = stickHits + 1 else stickMiss = stickMiss + 1 end
		if stickHits + stickMiss > 600 then
			stickHits, stickMiss = math.floor(stickHits / 2), math.floor(stickMiss / 2)
		end
		leftYaw = nil
	end

	-- Learn what one mouse unit is worth from the request made last frame. The
	-- player's sensitivity is unknowable from the client, and this game has a
	-- per-weapon zoom multiplier on top, so it is measured continuously rather
	-- than set once.
	if preYaw ~= nil and (math.abs(askedX) >= 1 or math.abs(askedY) >= 1) then
		if math.abs(askedX) >= 1 then
			local s = -angleDelta(preYaw, yawNow) / askedX
			if s == s and s > 0 and s < 0.1 then
				mouseSensY = (mouseSensY == 0) and s or (mouseSensY * 0.85 + s * 0.15)
			end
		end
		if math.abs(askedY) >= 1 then
			local s = -(pitchNow - prePitch) / askedY
			if s == s and s > 0 and s < 0.1 then
				mouseSensP = (mouseSensP == 0) and s or (mouseSensP * 0.85 + s * 0.15)
			end
		end
		STATE.mouseSens = mouseSensY
	end
	askedX, askedY = 0, 0
	preYaw, prePitch = nil, nil

	local prevNX, prevNY = lastNX, lastNY
	lastNX, lastNY = 0, 0

	if not aimActive() then
		STATE.target, STATE.waitMs, stickyName = "-", 0, nil
		carryX, carryY = 0, 0       -- a stale remainder must not fire a stray move
		return
	end

	local nowMs = os.clock() * 1000
	local pick

	-- Sticky is by NAME, because the model it was locked onto may have been
	-- rebuilt since the last frame (header 3) - a model-keyed lock would break
	-- several times a second on its own.
	if CONFIG.aimSticky and stickyName then
		eachTarget(function(info)
			if pick or info.name ~= stickyName then return end
			local part = aimPointOf(info)
			if not part or not part.Parent then return end
			local sp = camera:WorldToViewportPoint(part.Position)
			if sp.Z <= 0 then return end
			local px = (Vector2.new(sp.X, sp.Y) - centre()).Magnitude
			if px > CONFIG.aimFov * 1.35 then return end
			if CONFIG.aimVisible and not visible(part.Position) then return end
			pick = { name = info.name, part = part, px = px, info = info }
		end)
	end

	if not pick then
		pick = pickTarget()
		if pick and pick.name ~= stickyName then
			local lo = math.min(CONFIG.humReactMin, CONFIG.humReactMax)
			local hi = math.max(CONFIG.humReactMin, CONFIG.humReactMax)
			reactUntil = (CONFIG.hum and hi > 0) and (nowMs + math.random(lo, hi)) or 0
			lockedAt = nowMs
		end
	end

	if not pick or not pick.part or not pick.part.Parent then
		STATE.target, STATE.waitMs, stickyName = "-", 0, nil
		return
	end
	stickyName = pick.name
	STATE.target = pick.name

	if reactUntil > nowMs then
		STATE.waitMs = math.floor(reactUntil - nowMs)
		return
	end
	STATE.waitMs = 0

	local smoothH, smoothV = CONFIG.aimSmoothH, CONFIG.aimSmoothV
	if CONFIG.hum and CONFIG.humRampMs > 0 then
		local age = nowMs - lockedAt
		if age < CONFIG.humRampMs then
			local slow = 3 - 2 * (age / CONFIG.humRampMs)
			smoothH, smoothV = smoothH * slow, smoothV * slow
		end
	end

	local pos = cf.Position
	local curPitch, curYaw = pitchNow - prevNY, yawNow - prevNX
	-- the ARRIVAL point, not the current one: this game's bullets travel and fall
	local want = CFrame.lookAt(pos, predictPoint(pick.part, pick.name))
	local wantPitch, wantYaw = want:ToOrientation()

	local dYaw   = angleDelta(curYaw, wantYaw)
	local dPitch = angleDelta(curPitch, wantPitch)

	-- The honest self-measurement: a game that overrides the view leaves this
	-- high however the sliders are set, and the CHECK page prints it rather than
	-- claiming the assist works.
	local errDeg = math.deg(math.sqrt(dYaw * dYaw + dPitch * dPitch))
	STATE.aimErr = (STATE.aimErr == 0) and errDeg or (STATE.aimErr * 0.95 + errDeg * 0.05)

	if CONFIG.hum and CONFIG.humDeadPx > 0 and pick.px <= CONFIG.humDeadPx then
		dYaw, dPitch = 0, 0
	end

	local moveYaw   = dYaw   * approach(smoothH, dt)
	local movePitch = dPitch * approach(smoothV, dt)

	-- The degrees-per-second ceiling. A smoothing divisor is a FRACTION of the
	-- remaining angle, so at point blank even a slow-looking divisor turns the
	-- view at a few thousand degrees a second. Capped on yaw and pitch together
	-- so a diagonal flick is capped like a flat one.
	if CONFIG.hum and CONFIG.humMaxDegS > 0 then
		local cap = math.rad(CONFIG.humMaxDegS) * dt
		local mag = math.sqrt(moveYaw * moveYaw + movePitch * movePitch)
		if mag > cap and mag > 0 then
			local k = cap / mag
			moveYaw, movePitch = moveYaw * k, movePitch * k
		end
	end

	local nx, ny = noiseStep(dt)
	local mode = deliverMode()
	STATE.deliver = mode

	if mode == "Mouse" then
		-- WHICH sensitivity estimate to trust, and it is not the obvious one.
		--
		-- The assist can learn from its own requests (mouseSensY): ask for N
		-- units, look at the view next frame, divide. In this game that reads
		-- LOW - 0.00084 rad per unit against 0.00275 measured from the player's
		-- own hand - because PF smooths mouse input, so the view is still
		-- catching up when the sample is taken. Believing it makes every request
		-- about three times too large, the aim overshoots, corrects back, and the
		-- result is the crosshair sitting on nobody and twitching: reported as
		-- "it flickers back and forth and never fully locks".
		--
		-- The RCS pass measures the same constant the honest way - the player's
		-- RAW mouse delta against what the view then did - so that estimate wins
		-- whenever it exists.
		local sy = (sensY ~= 0) and sensY or ((mouseSensY ~= 0) and mouseSensY or 0.007)
		local sp = (sensP ~= 0) and sensP or ((mouseSensP ~= 0) and mouseSensP or sy)

		-- Dead-time compensation. PF does not turn the view in the same frame the
		-- movement is sent, so asking for the whole remaining angle again on the
		-- next frame asks twice for the same correction. What was requested and
		-- has not shown up yet is subtracted, and decays so a request that never
		-- lands cannot block the next one.
		moveYaw   = moveYaw   - pendYaw
		movePitch = movePitch - pendPitch
		-- positive x turns right and LOWERS yaw; positive y looks down and
		-- LOWERS pitch - hence the minus on both
		local dx = -(moveYaw + nx) / sy + carryX
		local dy = -(movePitch + ny) / sp + carryY

		-- CARRY the sub-pixel remainder instead of dropping it. mousemoverel
		-- moves whole units, and one unit is about 0.17 deg at the sensitivity
		-- measured here - so a request smaller than that used to be thrown away
		-- entirely, and the aim could never close the last fraction of a degree
		-- however low the smoothing was set. That is what "it never fully locks
		-- even on Raw" was. Accumulated, those fractions become a unit and the
		-- aim converges properly.
		local sendX = (dx >= 0) and math.floor(dx) or math.ceil(dx)
		local sendY = (dy >= 0) and math.floor(dy) or math.ceil(dy)
		carryX, carryY = dx - sendX, dy - sendY
		-- never let the carry run away while the aim is idle
		carryX = math.clamp(carryX, -1, 1)
		carryY = math.clamp(carryY, -1, 1)

		if sendX ~= 0 or sendY ~= 0 then
			askedX, askedY = sendX, sendY
			preYaw, prePitch = yawNow, pitchNow
			scriptWroteMouse = true      -- keeps the RCS estimate off this frame
			pendYaw   = pendYaw   + (-sendX * sy)
			pendPitch = pendPitch + (-sendY * sp)
			pcall(function() moveMouse(sendX, sendY) end)
		end
		lastNX, lastNY = 0, 0
	else
		lastNX, lastNY = nx, ny
		camera.CFrame = CFrame.new(pos)
			* CFrame.fromOrientation(curPitch + movePitch + ny, curYaw + moveYaw + nx, 0)
		leftYaw = curYaw + moveYaw + nx
	end

	STATE.engaged = true
end

--------------------------------------------------------------------------------
-- the hitbox magnet: removed, and why
--------------------------------------------------------------------------------
--
-- It worked exactly as designed and it still did nothing, so it is gone rather
-- than sitting on a page pretending. Moving an enemy anchor onto the bullet
-- line made this client grade its own shot against the moved box and send the
-- hit itself - traced, with NetworkClient.send showing bullethit=3 going out on
-- a valid key - and the server confirmed none of them. Phantom Forces
-- re-validates the trajectory, so a hit claim that does not match where the
-- bullet actually went is discarded.
--
-- The same measurement closes hit-part spoofing: rewriting Torso to Head on a
-- legitimate hit comes back from the server with the part echoed but the
-- headshot flag set FALSE and the damage unchanged at 56.0. The server decides.

--------------------------------------------------------------------------------
-- movement and world
--------------------------------------------------------------------------------
--
-- The character object is reachable once the client runs on the main thread, and
-- it hands out the movement directly: `setWalkSpeedMult`, `setStamina`,
-- `getSpeed`, `getRootPart`, `isGrounded`. Measured: setWalkSpeedMult(2.5) took
-- the peak speed from 14 to 25.5 and the ground covered from 2.5 to 8.2 studs a
-- second, so the multiplier is real and something clamps it below what is asked.
--
-- What does NOT work, measured: writing `CharacterConfig.adrenalineMovementConfig
-- .*.jumpHeight` from 3.3 to 14 left the jump at 2.9 studs. The character reads
-- that config when it is built, so changing it afterwards changes nothing - no
-- super jump ships on the back of it.
--
-- Phantom Forces validates movement server side. Speed is therefore presented
-- with the measured speed next to it rather than as a promise, and it is left to
-- the player to decide how far to push a number the server is watching.

local charIface = nil

local function characterObject()
	if not charIface then
		if not parallelOnMainThread() then return nil end
		local ok = pcall(function()
			for _, v in ipairs(getgc(true)) do
				if type(v) == "table" and type(rawget(v, "getCharacterObject")) == "function" then
					charIface = v
					return
				end
			end
		end)
		if not ok or not charIface then return nil end
	end
	local ok, obj = pcall(charIface.getCharacterObject)
	return ok and obj or nil
end

local speedApplied = false

local function movementPass()
	local obj = characterObject()
	if not obj then
		STATE.speed = 0
		return
	end

	local ok, s = pcall(obj.getSpeed, obj)
	STATE.speed = (ok and tonumber(s)) or 0

	if CONFIG.speed then
		pcall(function() obj:setWalkSpeedMult(math.max(1, CONFIG.speedMult)) end)
		speedApplied = true
	elseif speedApplied then
		-- put it back exactly once, not every tick: writing 1 continuously would
		-- fight the game's own sprint and slide multipliers
		pcall(function() obj:setWalkSpeedMult(1) end)
		speedApplied = false
	end

	if CONFIG.infStamina then
		pcall(function() obj:setStamina(1) end)
	end
end

task.spawn(function()
	while _G.__SELPF == GEN do
		local ok, err = pcall(movementPass)
		if not ok then note("movement: " .. tostring(err)) end
		task.wait(0.1)
	end
end)

--------------------------------------------------------------------------------
-- flight
--------------------------------------------------------------------------------
--
-- The root part is ANCHORED and the game drives it by CFrame from its own
-- movement step, so there is no velocity to set. Pushing the CFrame upward
-- against that step barely works - measured 4.2 studs out of 27.5 asked for, and
-- it fell straight back - because the step recomputes the fall every frame from
-- `workspace.Gravity`, which CharacterObject reads live (`local v159 =
-- -workspace.Gravity`).
--
-- Set that to 0 first and the same push holds: the same test went from 2.8 to
-- 28.0 studs and stayed at 28.0 after letting go, with no correction from the
-- server. Gravity is restored the moment flight is switched off, and captured on
-- the rising edge rather than assumed to be 128 - it is a map property and a
-- constant here would be wrong on the next one.

-- The map's real gravity, read ONCE at load and never written. Capturing it on
-- the rising edge of the toggle looked tidier and was a trap: if anything had
-- already zeroed it - a crashed run, a test, a second copy of the script - then
-- 0 is what gets "restored", and the player is left unable to jump or fall with
-- the feature switched OFF. That shipped and had to be undone by hand.
-- and NOT read once at load either: a fresh join starts on Roblox's default
-- 196.2 and Phantom Forces sets its own 128 a moment later, so a value captured
-- at load is simply the wrong one. This is observed continuously instead - the
-- last non-zero gravity seen while flight was off is by definition the map's.
local BASE_GRAVITY = (workspace.Gravity > 0) and workspace.Gravity or 128
local flyGravity = nil
local FLY_KEYS = {
	{ Enum.KeyCode.W, "look" }, { Enum.KeyCode.S, "-look" },
	{ Enum.KeyCode.D, "right" }, { Enum.KeyCode.A, "-right" },
	{ Enum.KeyCode.Space, "up" }, { Enum.KeyCode.LeftControl, "-up" },
}

local function restoreGravity()
	if flyGravity then
		workspace.Gravity = BASE_GRAVITY
		flyGravity = nil
	end
end

-- A safety net that does not depend on the toggle at all: if flight is off and
-- something has left the map without gravity, put it back. Cheap, and it means a
-- crashed or replaced run cannot strand the player.
task.spawn(function()
	while _G.__SELPF == GEN do
		if not CONFIG.fly then
			local g = workspace.Gravity
			if g > 0 then
				BASE_GRAVITY = g          -- the map's own value, seen live
			else
				workspace.Gravity = BASE_GRAVITY
				note("gravity was 0 with fly off - restored")
			end
		end
		task.wait(0.5)
	end
end)

local function flyPass(dt)
	if _G.__SELPF ~= GEN then restoreGravity() return end
	if not CONFIG.fly then restoreGravity() return end

	local obj = characterObject()
	local root = obj and obj:getRootPart()
	if not root or not root.Parent then restoreGravity() return end

	flyGravity = true
	workspace.Gravity = 0

	local cf = camera.CFrame
	local dir = Vector3.zero
	local pressed = 0
	for _, entry in ipairs(FLY_KEYS) do
		if UserInputService:IsKeyDown(entry[1]) then
			pressed = pressed + 1
			local axis = entry[2]
			local sign = 1
			if axis:sub(1, 1) == "-" then sign, axis = -1, axis:sub(2) end
			if axis == "look" then dir = dir + cf.LookVector * sign
			elseif axis == "right" then dir = dir + cf.RightVector * sign
			else dir = dir + Vector3.new(0, sign, 0) end
		end
	end

	-- HORIZONTAL COMES FROM THE GAME, VERTICAL FROM US. Walking is the movement
	-- step's own job and it does it well; fighting it with a second offset makes
	-- the character stutter between two ideas of where it is. What the step will
	-- not do with gravity off is climb, so only the vertical is added here - and
	-- it is added as an absolute rate rather than mixed into a normalised
	-- direction, or holding W alone would drain most of the lift into the walk.
	local vertical = dir.Y
	local horizontal = Vector3.new(dir.X, 0, dir.Z)
	local step = Vector3.zero
	if math.abs(vertical) > 0.01 then
		step = step + Vector3.new(0, vertical, 0)
	end
	if horizontal.Magnitude > 0.01 and not obj:isGrounded() then
		-- only once airborne, so ordinary walking is left alone
		step = step + horizontal.Unit
	end
	if step.Magnitude > 0.01 then
		root.CFrame = root.CFrame + step * (math.max(1, CONFIG.flySpeed) * dt)
	end

	STATE.flyAlt = root.Position.Y
	STATE.flyKeys = pressed
	STATE.flyFrames = (STATE.flyFrames or 0) + 1
end

local flyConn = RunService.Heartbeat:Connect(function(dt)
	local ok, err = pcall(flyPass, dt)
	if not ok then note("fly: " .. tostring(err)) end
end)

task.spawn(function()
	while _G.__SELPF == GEN do task.wait(1) end
	-- a re-execute must not leave the map without gravity
	restoreGravity()
	pcall(function() flyConn:Disconnect() end)
end)

-- The world settings need no hooks at all and work on a first join. They are
-- re-applied on a timer because the game writes Lighting itself on a round
-- change, and captured on the rising edge so switching them off restores what
-- the game had rather than a constant.
local savedLight = nil

local function worldPass()
	local L = game:GetService("Lighting")
	if (CONFIG.fullbright or CONFIG.noFog) and not savedLight then
		savedLight = { Brightness = L.Brightness, ClockTime = L.ClockTime,
			Ambient = L.Ambient, OutdoorAmbient = L.OutdoorAmbient,
			FogEnd = L.FogEnd, GlobalShadows = L.GlobalShadows }
	end
	if CONFIG.fullbright then
		L.Brightness = 3
		L.ClockTime = 14
		L.Ambient = Color3.fromRGB(178, 178, 178)
		L.OutdoorAmbient = Color3.fromRGB(178, 178, 178)
		L.GlobalShadows = false
	end
	if CONFIG.noFog then
		L.FogEnd = 1e6
	end
	-- Terrain grass is a single property and costs nothing to flip back, so it is
	-- not part of the saved-lighting bundle above.
	pcall(function() workspace.Terrain.Decoration = not CONFIG.noGrass end)
	if savedLight and not CONFIG.fullbright and not CONFIG.noFog then
		for k, v in pairs(savedLight) do pcall(function() L[k] = v end) end
		savedLight = nil
	end
end

task.spawn(function()
	while _G.__SELPF == GEN do
		local ok, err = pcall(worldPass)
		if not ok then note("world: " .. tostring(err)) end
		task.wait(1)
	end
end)

--------------------------------------------------------------------------------
-- reading the wire, and only reading it
--------------------------------------------------------------------------------
--
-- Nothing is ever sent. Listening is free and answers two things the client
-- cannot otherwise answer: what we spawned holding, and whether the server
-- accepted a hit.

local function tapNetwork()
	local ev = RS:FindFirstChild("RemoteEvent")
	if not ev then return end
	ev.OnClientEvent:Connect(function(cmd, a, b, c)
		if _G.__SELPF ~= GEN then return end
		if cmd == "bulletHitConfirm" then
			-- (victim, hitPart, position, damage, headshot, time). The headshot
			-- flag is the SERVER's own verdict, not an echo of what the client
			-- claimed - proven by rewriting the part name and watching it come
			-- back false anyway.
			STATE.snapHits = STATE.snapHits + 1
			if b == "Head" then
				STATE.snapPartHits = STATE.snapPartHits + 1
			end
		elseif cmd == "newbullets" and type(a) == "table" and a.player == plr then
			local bullet = a.bullets and a.bullets[1]
			if bullet then
				if typeof(bullet.velocity) == "Vector3" then
					measuredSpeed = bullet.velocity.Magnitude
					STATE.bulletSpeed = measuredSpeed
				end
				if typeof(bullet.acceleration) == "Vector3" then
					measuredGravity = math.abs(bullet.acceleration.Y)
				end
			end
		elseif cmd == "newspawn" and a == plr and type(c) == "table" then
			-- (player, position, loadout) - the loadout is keyed Primary /
			-- Secondary / Knife / Grenade, each with a Name
			local set = {}
			for slot, entry in pairs(c) do
				if type(entry) == "table" and type(entry.Name) == "string" then
					set[slot] = entry.Name
				end
			end
			myLoadout = set
		end
	end)
end
tapNetwork()

--------------------------------------------------------------------------------
-- trigger
--------------------------------------------------------------------------------
--
-- A real mouse click, so the game's own weapon code runs the shot exactly as it
-- would for a human. Nothing is fabricated and no remote is fired.
--
-- The crosshair is NOT ViewportSize/2 blindly: this client reported the mouse at
-- (763, 449) on a 1920x1080 viewport with a 58 px GUI inset, so the centre is
-- taken from the camera's own viewport and the inset is added when the ray is
-- built from a mouse position. In a locked first-person view the two agree; in
-- the menu they do not, which is exactly when the trigger must not fire.

local triggerParams = RaycastParams.new()
triggerParams.FilterType = Enum.RaycastFilterType.Exclude
triggerParams.IgnoreWater = true

local function triggerActive()
	if not CONFIG.trg then return false end
	if CONFIG.hum and CONFIG.humPanelOff and STATE.panelOpen then return false end
	if CONFIG.trgActive == "Always" then return true end
	return hotkeyHeld(CONFIG.trgKey)
end

-- Is an enemy under the crosshair? A single centre ray only ever hits a
-- stationary target, so the centre point is tested plus a ring of six at
-- trgFovPx pixels.
local function underCrosshair()
	local mid = centre()
	local camPos = camera.CFrame.Position
	local best, bestD

	local offsets = { Vector2.new(0, 0) }
	local r = math.max(0, CONFIG.trgFovPx)
	if r > 0 then
		for i = 0, 5 do
			local a = math.rad(i * 60)
			offsets[#offsets + 1] = Vector2.new(math.cos(a) * r, math.sin(a) * r)
		end
	end

	eachTarget(function(info)
		local parts = CONFIG.trgHeadOnly and { info.head } or info.parts
		for _, p in ipairs(parts) do
			if p and p.Parent then
				local dist = (camPos - p.Position).Magnitude
				if dist <= CONFIG.trgMaxDist then
					local sp = camera:WorldToViewportPoint(p.Position)
					if sp.Z > 0 then
						local sv = Vector2.new(sp.X, sp.Y)
						for _, off in ipairs(offsets) do
							if (sv - (mid + off)).Magnitude <= math.max(2, CONFIG.trgFovPx) then
								if (not CONFIG.trgVisible) or visible(p.Position) then
									if not bestD or dist < bestD then
										best, bestD = info.name, dist
									end
								end
								break
							end
						end
					end
				end
			end
		end
	end)
	return best
end

local function pullTrigger()
	if not clickFn then return false end
	local ok = pcall(clickFn)
	if ok then STATE.shots = STATE.shots + 1 end
	return ok
end

task.spawn(function()
	-- Its own thread rather than a render bind: it has to task.wait for the
	-- reaction delay, and a yield inside a render binding is a problem.
	while _G.__SELPF == GEN do
		local ok, err = pcall(function()
			if not triggerActive() then return end
			local who = underCrosshair()
			if not who then return end
			local lo = math.min(CONFIG.trgDelayMin, CONFIG.trgDelayMax)
			local hi = math.max(CONFIG.trgDelayMin, CONFIG.trgDelayMax)
			if hi > 0 then task.wait(math.random(lo, hi) / 1000) end
			-- Re-check AFTER the delay. Without this the trigger fires at where
			-- the enemy was 90 ms ago, which on a strafing player is a miss and a
			-- give-away in equal measure.
			if not triggerActive() then return end
			if underCrosshair() ~= who then return end
			if math.random(100) > CONFIG.trgChance then return end
			pullTrigger()
			task.wait(math.max(0, CONFIG.trgRefire) / 1000)
		end)
		if not ok then note("trigger: " .. tostring(err)) end
		task.wait(0.01)
	end
end)

--------------------------------------------------------------------------------
-- the round, read off the HUD
--------------------------------------------------------------------------------
--
-- There is no Status folder in this game: the round state is the HUD's own
-- labels, and they are real names because the game's GUI templates use them.

local function hudRead()
	local gui = plr:FindFirstChild("PlayerGui")
	gui = gui and gui:FindFirstChild("HudScreenGui")
	local main = gui and gui:FindFirstChild("Main")
	if not main then return nil end
	local st = main:FindFirstChild("DisplayStatus")
	local sc = main:FindFirstChild("DisplayRadarScore")
	sc = sc and sc:FindFirstChild("DisplayMatchScore")
	local function txt(parent, name)
		local l = parent and parent:FindFirstChild(name, true)
		return l and l.Text or "-"
	end
	local hp = st and st:FindFirstChild("DisplayHealth")
	-- the firemode label is rich text: [<font>850 A</font>]
	local fire = txt(st, "TextFiremode"):gsub("<[^>]->", "")
	return {
		hp    = txt(hp, "TextHealth"),
		mag   = txt(st, "TextMagCount"),
		spare = txt(st, "TextSpareCount"),
		nade  = txt(st, "TextGrenadeCount"),
		fire  = fire,
		timer = txt(sc, "TextMatchTimer"),
		mode  = txt(sc, "TextGameMode"),
	}
end

--------------------------------------------------------------------------------
-- panic key
--------------------------------------------------------------------------------

UserInputService.InputBegan:Connect(function(input, typing)
	if _G.__SELPF ~= GEN or typing then return end
	local k = keyFromName(CONFIG.panicKey)
	if k and input.KeyCode == k then
		CONFIG.aim = false
		CONFIG.trg = false
		note("PANIC - aim and trigger off")
	end
end)

--------------------------------------------------------------------------------
-- render binds
--------------------------------------------------------------------------------
--
-- Camera + 1 and + 2, so both run AFTER whatever the game does to the camera
-- this frame. Anything earlier is simply overwritten and the survival probe
-- would read zero.

for _, name in ipairs({ "SeluxPFAim", "SeluxPFESP", "SeluxPFSnap" }) do
	pcall(function() RunService:UnbindFromRenderStep(name) end)
end

RunService:BindToRenderStep("SeluxPFAim", Enum.RenderPriority.Camera.Value + 1,
	function(dt)
		if _G.__SELPF ~= GEN then
			pcall(function() RunService:UnbindFromRenderStep("SeluxPFAim") end)
			return
		end
		local ok, err = pcall(function() aimPass(dt) end)
		if not ok then note("aim: " .. tostring(err)) end
	end)

RunService:BindToRenderStep("SeluxPFESP", Enum.RenderPriority.Camera.Value + 2,
	function()
		if _G.__SELPF ~= GEN then
			pcall(function() RunService:UnbindFromRenderStep("SeluxPFESP") end)
			hideAll()
			hideAllChams()
			return
		end
		local ok, err = pcall(renderPass)
		if not ok then note("esp: " .. tostring(err)) end
	end)


--------------------------------------------------------------------------------
-- panel
--------------------------------------------------------------------------------

local UI = (_G.__SEL and _G.__SEL.ui) or loadstring(readfile("ui-template.lua"))()

-- The generation counter stops last run's LOOPS; it does not take last run's
-- PANEL off the screen. Both halves are needed: the stored handle for the normal
-- case, the sweep by name for a window whose handle was lost.
if _G.__SELPF_WIN then pcall(function() _G.__SELPF_WIN:Destroy() end) end
if UI.sweep then UI.sweep("SeluxPhantomPanel") end

-- BEFORE the panel is built: the controls read their initial value out of CONFIG
-- as they are created, so they come up on the saved state by themselves.
UI.config("phantomforces", CONFIG)

-- The saved switches are in CONFIG by now, so the hooks can be installed and
-- pointed at them in one go. installHooks is a no-op when the client is still
-- running its code in an Actor VM, which is the normal case on a first join.
pcall(installHooks)
pcall(syncMods)

-- Keep trying. The client's objects appear a few seconds into a join, and the
-- sweep is ~900 ms over half a million tables, so this is a handful of attempts
-- and then silence - not a poll that runs forever.
task.spawn(function()
	local tries = 0
	while _G.__SELPF == GEN and not HOOKS.installed and tries < 20 do
		task.wait(3)
		tries = tries + 1
		pcall(installHooks)
		if HOOKS.installed then pcall(syncMods) end
	end
end)

local win = UI.Window({
	name = "SeluxPhantomPanel",
	title = "SELUX", accentTitle = "PHANTOM", subtitle = "seltonmt",
})
_G.__SELPF_WIN = win

local KEYS = { "MouseButton2", "MouseButton1", "LeftShift", "LeftAlt", "LeftControl",
	"C", "E", "Q", "F", "V", "X", "CapsLock" }

--------------------------------------------------------------- ESP
-- Luau allows 200 locals per function and this chunk reached exactly that while
-- the panel grew. The page and card handles below are only needed while their
-- page is being built, so the whole section is wrapped in a do-block and their
-- registers are released at the end of it; the readouts outlive it and are
-- declared out here.
local teamOut, aimOut, trgOut, modOut, silOut, moveOut, rcsOut
local roundOut, boardOut, diagOut

do

local espPage = win:Page("ESP", UI.icon.eye or UI.icon.target)

local espCard = espPage:Card("DRAW", 1):Accent()
espCard:Toggle("ESP enabled", CONFIG.esp, function(v) CONFIG.esp = v end)
espCard:Toggle("Box", CONFIG.espBox, function(v) CONFIG.espBox = v end)
espCard:Toggle("Box fill", CONFIG.espBoxFill, function(v) CONFIG.espBoxFill = v end)
espCard:Toggle("Name", CONFIG.espName, function(v) CONFIG.espName = v end)
espCard:Toggle("Distance", CONFIG.espInfo, function(v) CONFIG.espInfo = v end)
espCard:Toggle("Kills and deaths", CONFIG.espScore, function(v) CONFIG.espScore = v end,
	"read off the scoreboard, so it works for every player")
espCard:Toggle("Health bar", CONFIG.espHealth, function(v) CONFIG.espHealth = v end,
	"only drawn when the game publishes a health value", UI.theme.warn)
espCard:Toggle("Tracer", CONFIG.espTracer, function(v) CONFIG.espTracer = v end)
espCard:Toggle("Head dot", CONFIG.espHeadDot, function(v) CONFIG.espHeadDot = v end)
espCard:Toggle("Skeleton", CONFIG.espSkeleton, function(v) CONFIG.espSkeleton = v end,
	"the six replicated anchors, joined to the head")

local visCard = espPage:Card("VISIBILITY", 2)
visCard:Toggle("Visible only", CONFIG.espVisOnly, function(v) CONFIG.espVisOnly = v end,
	"hide anyone behind a wall completely", UI.theme.warn)
visCard:Toggle("Dim hidden targets", CONFIG.espDimHidden,
	function(v) CONFIG.espDimHidden = v end, "draw them faded instead", UI.theme.good)
visCard:Slider("Max distance", 100, 5000, CONFIG.maxDist, function(v) CONFIG.maxDist = v end)
visCard:Slider("Text size", 12, 20, CONFIG.espTextSize,
	function(v) CONFIG.espTextSize = v end,
	"floored at 12 - below that every Drawing face falls apart")

local colCard = espPage:Card("COLOURS", 1)
colCard:Colour("Enemy", CONFIG.colEnemy, function(c) CONFIG.colEnemy = c end,
	"behind a wall")
colCard:Colour("Visible", CONFIG.colVisible, function(c) CONFIG.colVisible = c end,
	"line of sight is clear")
colCard:Colour("Text", CONFIG.colText, function(c) CONFIG.colText = c end)
colCard:Colour("FOV circle", CONFIG.colFov, function(c) CONFIG.colFov = c end)

local chamCard = espPage:Card("CHAMS", 2)
chamCard:Toggle("Chams", CONFIG.chams, function(v) CONFIG.chams = v end,
	"a Highlight on the body, drawn through walls")
chamCard:Slider("Fill", 0, 1, CONFIG.chamsFill, function(v) CONFIG.chamsFill = v end)
chamCard:Slider("Outline", 0, 1, CONFIG.chamsOutline,
	function(v) CONFIG.chamsOutline = v end, "0 is a hard edge, 1 is none")
chamCard:Label("They take the ESP colour, so a body that goes green has line of "
	.. "sight. The Highlight lives outside the game's tree and is re-pointed "
	.. "every frame, because the model under it is rebuilt several times a second.")

local teamCard = espPage:Card("TARGETS", 0)
teamCard:Dropdown("Team filter", { "Auto", "Everyone" }, CONFIG.teamMode,
	function(v) CONFIG.teamMode = v end,
	"Auto reads the scoreboard: Player.Team is nil for everyone in this game")
teamCard:Toggle("Invert targets", CONFIG.teamInvert, function(v) CONFIG.teamInvert = v end,
	"use when the split is right but the sides are swapped", UI.theme.warn)
teamOut = teamCard:Readout(4)

end

do

--------------------------------------------------------------- AIM
local aimPage = win:Page("AIM", UI.icon.target)

local aimCard = aimPage:Card("ACTIVATION", 1):Accent()
aimCard:Toggle("Aimbot", CONFIG.aim, function(v) CONFIG.aim = v end)
aimCard:Dropdown("Mode", { "Hotkey", "Always", "While firing" }, CONFIG.aimActive,
	function(v) CONFIG.aimActive = v end)
aimCard:Dropdown("Aim key", KEYS, CONFIG.aimKey, function(v) CONFIG.aimKey = v end)
aimCard:Dropdown("Hit part", { "Head", "Torso", "Nearest" }, CONFIG.aimPart,
	function(v) CONFIG.aimPart = v end)
aimCard:Dropdown("Target selection", { "Crosshair", "Closest" }, CONFIG.aimPick,
	function(v) CONFIG.aimPick = v end)
aimCard:Dropdown("Aim method", { "Mouse", "Auto", "Camera" }, CONFIG.aimDeliver,
	function(v) CONFIG.aimDeliver = v end,
	"measured here: camera writes are thrown away within a frame")
aimCard:Toggle("Sticky target", CONFIG.aimSticky, function(v) CONFIG.aimSticky = v end)
aimCard:Toggle("Visible only", CONFIG.aimVisible, function(v) CONFIG.aimVisible = v end,
	"never aim through a wall", UI.theme.good)
aimCard:Toggle("Show FOV circle", CONFIG.aimCircle, function(v) CONFIG.aimCircle = v end)
aimCard:Toggle("Bullet drop prediction", CONFIG.aimPredict,
	function(v) CONFIG.aimPredict = v end,
	"bullets here fly 2800-2950 studs per second and fall at 196", UI.theme.good)
aimCard:Toggle("Target prediction", CONFIG.aimLead, function(v) CONFIG.aimLead = v end,
	"aim where they will be when the bullet arrives", UI.theme.good)

local tuneCard = aimPage:Card("TUNING", 2)
tuneCard:Slider("FOV (pixels)", 5, 600, CONFIG.aimFov, function(v) CONFIG.aimFov = v end)
tuneCard:Slider("Smooth H", 1, 100, CONFIG.aimSmoothH,
	function(v) CONFIG.aimSmoothH = v end, "higher is slower")
tuneCard:Slider("Smooth V", 1, 100, CONFIG.aimSmoothV, function(v) CONFIG.aimSmoothV = v end)
tuneCard:Slider("Max distance", 50, 3000, CONFIG.aimMaxDist,
	function(v) CONFIG.aimMaxDist = v end)
aimOut = tuneCard:Readout(3)

end

do

--------------------------------------------------------------- TRIGGER
local trgPage = win:Page("TRIGGER", UI.icon.bolt or UI.icon.target)

local trgCard = trgPage:Card("TRIGGER", 1):Accent()
trgCard:Toggle("Trigger", CONFIG.trg, function(v) CONFIG.trg = v end)
trgCard:Dropdown("Activation", { "Hotkey", "Always" }, CONFIG.trgActive,
	function(v) CONFIG.trgActive = v end)
trgCard:Dropdown("Trigger key", KEYS, CONFIG.trgKey, function(v) CONFIG.trgKey = v end)
trgCard:Toggle("Head only", CONFIG.trgHeadOnly, function(v) CONFIG.trgHeadOnly = v end)
trgCard:Toggle("Visible only", CONFIG.trgVisible, function(v) CONFIG.trgVisible = v end,
	"never shoot at a wall", UI.theme.good)

local trgTune = trgPage:Card("TIMING", 2)
trgTune:Slider("Reaction min (ms)", 0, 400, CONFIG.trgDelayMin,
	function(v) CONFIG.trgDelayMin = v end)
trgTune:Slider("Reaction max (ms)", 0, 400, CONFIG.trgDelayMax,
	function(v) CONFIG.trgDelayMax = v end, "a fixed value is a pattern")
trgTune:Slider("Refire lockout (ms)", 0, 1000, CONFIG.trgRefire,
	function(v) CONFIG.trgRefire = v end)
trgTune:Slider("Hit chance (%)", 10, 100, CONFIG.trgChance,
	function(v) CONFIG.trgChance = v end)
trgTune:Slider("Pixel FOV", 0, 30, CONFIG.trgFovPx, function(v) CONFIG.trgFovPx = v end,
	"a single centre ray only ever hits a standing target")
trgTune:Slider("Max distance", 50, 2000, CONFIG.trgMaxDist,
	function(v) CONFIG.trgMaxDist = v end)
trgOut = trgTune:Readout(3)

end

do

--------------------------------------------------------------- GUN MODS
local modPage = win:Page("GUN MODS", UI.icon.wrench or UI.icon.bolt)

local modCard = modPage:Card("GUN MODS", 1):Accent()
modCard:Toggle("No Recoil", CONFIG.noRecoil, function(v)
	CONFIG.noRecoil = v syncMods()
end, "measured: 2.49 deg of climb over a burst becomes 0.01", UI.theme.good)
modCard:Toggle("No Spread", CONFIG.noSpread, function(v)
	CONFIG.noSpread = v syncMods()
end, "measured: 1.02 deg of bloom becomes 0.06", UI.theme.good)
modCard:Toggle("No Sway", CONFIG.noSway, function(v) CONFIG.noSway = v syncMods() end)
modCard:Toggle("No Equip Time", CONFIG.noEquipTime,
	function(v) CONFIG.noEquipTime = v syncMods() end)
modCard:Toggle("Instant ADS", CONFIG.instantAds,
	function(v) CONFIG.instantAds = v syncMods() end)
modCard:Toggle("Rapid Fire", CONFIG.rapidFire, function(v)
	CONFIG.rapidFire = v syncMods()
end, "UNVERIFIED - the server may pace shots regardless", UI.theme.warn)
modCard:Slider("Rapid Fire rate", 200, 3000, CONFIG.fireRate,
	function(v) CONFIG.fireRate = v syncMods() end)

local modCard2 = modPage:Card("MORE GUN MODS", 1)
modCard2:Toggle("No Camera Bob", CONFIG.noBob, function(v) CONFIG.noBob = v syncMods() end,
	"swingmod and aimswingmod - the two values the gun asks for most often")
modCard2:Toggle("No Suppression", CONFIG.noSuppression,
	function(v) CONFIG.noSuppression = v syncMods() end,
	"the screen effect when somebody shoots near you")
modCard2:Toggle("No Bolt Re-chamber", CONFIG.noBolt,
	function(v) CONFIG.noBolt = v syncMods() end,
	"for bolt actions - drops requirechamber and the bolt time")
modCard2:Toggle("Max Stability", CONFIG.stability,
	function(v) CONFIG.stability = v syncMods() end,
	"hipfire stability to 1 and the aim kick multiplier to 0")
modCard2:Toggle("Fast Reload", CONFIG.fastReload,
	function(v) CONFIG.fastReload = v syncMods() end,
	"the reload time IS the animation length, so this shortens that")
modCard2:Slider("Reload time left", 0.05, 1, CONFIG.reloadFactor,
	function(v) CONFIG.reloadFactor = v syncMods() end,
	"0.3 means it takes 30 percent as long; 0.05 is as close to instant as it goes")

local modInfo = modPage:Card("REQUIREMENTS", 2)
modOut = modInfo:Readout(5)
modInfo:Label("This game runs its client in an Actor VM, where nothing can be "
	.. "hooked from outside. One Roblox debug flag moves that code onto the main "
	.. "thread, and then all of the above works. It only takes effect on a fresh "
	.. "join, so the button below sets it and puts you back into the SAME server.")
modInfo:Button("Enable and rejoin this server", function()
	local setf = globalFn("setfflag")
	if not setf then note("this executor has no setfflag") return end
	local ok = pcall(setf, "DebugRunParallelLuaOnMainThread", "true")
	if not ok then note("setfflag was refused") return end
	note("flag set - rejoining")
	task.spawn(function()
		task.wait(0.6)
		pcall(function()
			game:GetService("TeleportService")
				:TeleportToPlaceInstance(game.PlaceId, game.JobId, plr)
		end)
	end)
end, UI.theme.warn)

end

do

--------------------------------------------------------------- SILENT
local silPage = win:Page("SILENT", UI.icon.sword or UI.icon.target)
local silCard = silPage:Card("SILENT AIM", 1):Accent()
silCard:Toggle("Silent Aim", CONFIG.silent, function(v)
	CONFIG.silent = v syncMods()
	HOOKS.silentShots = 0
end, "shoot normally, the bullet goes to the target", UI.theme.bad)
silCard:Dropdown("Hit part", { "Head", "Torso" }, CONFIG.silentPart,
	function(v) CONFIG.silentPart = v end)
silCard:Slider("FOV (pixels)", 20, 800, CONFIG.silentFov,
	function(v) CONFIG.silentFov = v end,
	"how far from your crosshair a target may be")
silCard:Slider("Max distance", 100, 3000, CONFIG.silentMaxDist,
	function(v) CONFIG.silentMaxDist = v end)
silCard:Toggle("Visible only", CONFIG.silentVisible,
	function(v) CONFIG.silentVisible = v end,
	"a wall still stops the bullet, so bending it into one wastes the shot",
	UI.theme.good)
silCard:Toggle("Lead moving targets", CONFIG.silentLead,
	function(v) CONFIG.silentLead = v end,
	"off by default - a bad velocity estimate throws the shot further than the "
	.. "lead ever gains", UI.theme.warn)
silCard:Toggle("Show FOV circle", CONFIG.silentCircle,
	function(v) CONFIG.silentCircle = v end)
silCard:Colour("FOV colour", CONFIG.colSilentFov,
	function(c) CONFIG.colSilentFov = c end)

silOut = silPage:Card("WHAT THE SERVER SEES", 2):Readout(6)
silPage:Card("HOW THIS ONE WORKS", 2):Label(
	"It bends the BULLET, it does not claim a hit. The first version replaced the "
	.. "game's answer to 'what did I hit' - the packets went out correctly and the "
	.. "server confirmed none of them, because it re-checks the trajectory. "
	.. "Rewriting the bullet's velocity instead means the shot really travels at "
	.. "the target, so the game reports it the ordinary way and there is nothing "
	.. "to disagree with. The cost is the opposite of the aimbot's: your camera "
	.. "never moves, so a killcam shows nothing, but the shot itself sits in the "
	.. "server's log leaving the barrel at an angle your view never had.")

end

do

--------------------------------------------------------------- MOVEMENT
local movePage = win:Page("MOVEMENT", UI.icon.run or UI.icon.user)
local moveCard = movePage:Card("MOVEMENT", 1):Accent()
moveCard:Toggle("Speed", CONFIG.speed, function(v) CONFIG.speed = v end,
	"the server watches movement in this game - keep it modest", UI.theme.warn)
moveCard:Slider("Speed multiplier", 1, 3, CONFIG.speedMult,
	function(v) CONFIG.speedMult = v end,
	"measured: x2.5 asked gives about x1.8 on the ground")
moveCard:Toggle("Infinite Stamina", CONFIG.infStamina,
	function(v) CONFIG.infStamina = v end)
moveCard:Toggle("Fly", CONFIG.fly, function(v) CONFIG.fly = v end,
	"WASD to move, Space up, Left Ctrl down - sets map gravity to 0 while on",
	UI.theme.warn)
moveCard:Slider("Fly speed", 10, 200, CONFIG.flySpeed,
	function(v) CONFIG.flySpeed = v end)
moveCard:Label("No super jump: the jump height lives in a config the character "
	.. "reads once when it spawns, so writing it afterwards changes nothing - "
	.. "3.3 raised to 14 still measured a 2.9 stud jump.")
moveOut = movePage:Card("MEASURED", 2):Readout(3)

local worldCard = movePage:Card("WORLD", 2)
worldCard:Toggle("Fullbright", CONFIG.fullbright, function(v) CONFIG.fullbright = v end)
worldCard:Toggle("No Fog", CONFIG.noFog, function(v) CONFIG.noFog = v end)
worldCard:Toggle("No Grass", CONFIG.noGrass, function(v) CONFIG.noGrass = v end)
worldCard:Label("No custom FOV here on purpose: this game rewrites the field of "
	.. "view every frame for scoping, so forcing a value either gets thrown away "
	.. "or breaks the zoom.")

end

do

--------------------------------------------------------------- RECOIL
local rcsPage = win:Page("RECOIL", UI.icon.wave or UI.icon.chart)
local rcsCard = rcsPage:Card("RECOIL CONTROL", 1):Accent()
rcsCard:Toggle("Recoil Compensation", CONFIG.rcs, function(v) CONFIG.rcs = v end,
	"works without the FFlag - No Recoil on the GUN MODS page is stronger")
rcsCard:Slider("Compensation (%)", 0, 100, CONFIG.rcsPct,
	function(v) CONFIG.rcsPct = v end)
rcsCard:Slider("Max per frame (deg)", 1, 12, CONFIG.rcsMaxDeg,
	function(v) CONFIG.rcsMaxDeg = v end, "a clamp, so nothing oscillates")
rcsCard:Label("No spray pattern is read. Your sensitivity is measured from your "
	.. "own mouse while you are NOT firing, and while you are, whatever pitch is "
	.. "left after subtracting your hand is the recoil. Both numbers are below - "
	.. "if the kick stays at 0.00 during a burst there is nothing to compensate "
	.. "and this page cannot help.")
rcsOut = rcsPage:Card("MEASUREMENT", 2):Readout(4)

end

do

--------------------------------------------------------------- HUMAN
local humPage = win:Page("HUMAN", UI.icon.shield or UI.icon.user)
local humCard = humPage:Card("HOW HUMAN IT LOOKS", 1):Accent()
humCard:Label("Nothing in a client can hide where the crosshair was. These "
	.. "numbers ARE the safety - not obscurity.")
humCard:Dropdown("Preset", { "Legit", "Normal", "Raw" }, "Normal", function(v)
	local set = PRESETS[v]
	if not set then return end
	for k, val in pairs(set) do CONFIG[k] = val end
	note("preset " .. v .. " applied - reopen the panel to see the sliders move")
end)
humCard:Toggle("Humanisation", CONFIG.hum, function(v) CONFIG.hum = v end,
	"reaction delay, wind-up, wander, deadzone and a speed ceiling", UI.theme.good)
humCard:Toggle("Pause while the panel is open", CONFIG.humPanelOff,
	function(v) CONFIG.humPanelOff = v end)
humCard:Slider("Reaction min (ms)", 0, 500, CONFIG.humReactMin,
	function(v) CONFIG.humReactMin = v end)
humCard:Slider("Reaction max (ms)", 0, 500, CONFIG.humReactMax,
	function(v) CONFIG.humReactMax = v end)
humCard:Slider("Wind-up (ms)", 0, 800, CONFIG.humRampMs, function(v) CONFIG.humRampMs = v end)
humCard:Slider("Wander (deg)", 0, 3, CONFIG.humNoise, function(v) CONFIG.humNoise = v end)
humCard:Slider("Deadzone (px)", 0, 30, CONFIG.humDeadPx, function(v) CONFIG.humDeadPx = v end)
humCard:Slider("Speed ceiling (deg/s)", 30, 1200, CONFIG.humMaxDegS,
	function(v) CONFIG.humMaxDegS = v end, "the single most important number here",
	UI.theme.warn)
humCard:Dropdown("Panic key", { "F1", "F2", "F3", "F4" }, CONFIG.panicKey,
	function(v) CONFIG.panicKey = v end)

end

do

--------------------------------------------------------------- ROUND
local roundPage = win:Page("ROUND", UI.icon.list or UI.icon.info)
local roundCard = roundPage:Card("THE MATCH", 1):Accent()
roundOut = roundCard:Readout(6)
local boardCard = roundPage:Card("SCOREBOARD", 2)
boardOut = boardCard:Readout(10)

end

do

--------------------------------------------------------------- CHECK
local diagPage = win:Page("CHECK", UI.icon.info or UI.icon.list)
local diagCard = diagPage:Card("WHAT IS ACTUALLY MEASURED", 1):Accent()
diagOut = diagCard:Label("-")
diagCard:Label("Phantom Forces randomises every instance name and rebuilds the "
	.. "character models several times a second, so this page shows the things "
	.. "that would silently stop working: how many models are being read, how "
	.. "fast they churn, which click transport arrives, and how much of a camera "
	.. "write survives.")

end

win:Home()
win:SetMaster(CONFIG.esp, "ESP running")
win:OnMaster(function(on) CONFIG.esp = on end)
win:Refresh()

--------------------------------------------------------------------------------
-- panel refresh
--------------------------------------------------------------------------------

task.spawn(function()
	probeClick()
	while _G.__SELPF == GEN do
		local ok, err = pcall(function()
			STATE.panelOpen = win.open == true

			teamOut:set(table.concat({
				"you       " .. STATE.myTeam,
				"source    " .. STATE.teamNote,
				"bodies    " .. STATE.alive .. " read, " .. STATE.targets .. " drawn",
				"churn     " .. STATE.churn .. " models rebuilt per second",
			}, "\n"))

			local wName, wStats = heldWeapon()
			STATE.weapon = wName
			aimOut:set(table.concat({
				"target    " .. STATE.target
					.. (STATE.waitMs > 0 and ("   reacting " .. STATE.waitMs .. "ms") or ""),
				"delivery  " .. STATE.deliver
					.. (STATE.mouseSens > 0
						and string.format("   %.5f rad/unit", STATE.mouseSens) or ""),
				string.format("aim err   %.2f deg", STATE.aimErr),
				"weapon    " .. wName,
				"bullet    " .. (STATE.bulletSpeed > 0
					and string.format("%.0f studs/s (measured from your own shot)",
						STATE.bulletSpeed)
					or ((wStats and (tostring(wStats.bulletspeed)
						.. " studs/s (from the database - fire once to measure it)"))
						or "unknown")),
				string.format("drop      aiming %.2f studs high", STATE.dropStuds),
			}, "\n"))

			local nOvr = 0
			for _ in pairs(HOOKS.statOverride) do nOvr = nOvr + 1 end
			modOut:set(table.concat({
				"flag      " .. (fflagOn() == nil and "no setfflag here"
					or (fflagOn() and "set" or "not set")),
				"client    " .. (parallelOnMainThread()
					and "main thread - hooks possible" or "Actor VM - hooks impossible"),
				"hooks     " .. HOOKS.note,
				"stats     " .. nOvr .. " overridden right now",
				"hits      " .. STATE.snapHits .. " confirmed by the server",
			}, "\n"))

			trgOut:set(table.concat({
				"click     " .. STATE.clickWay,
				"shots     " .. STATE.shots,
				"armed     " .. (triggerActive() and "yes" or "no"),
			}, "\n"))

			rcsOut:set(table.concat({
				string.format("sens      %.5f rad per mouse unit", STATE.rcsSens),
				string.format("kick      %.2f deg left after your hand", STATE.rcsKick),
				"firing    " .. (firing() and "yes" or "no"),
				"taking    " .. (CONFIG.rcs and (CONFIG.rcsPct .. "%") or "off"),
			}, "\n"))

			STATE.silentShots = HOOKS.silentShots or 0
			STATE.silentTarget = HOOKS.silentTarget or "-"
			silOut:set(table.concat({
				"hook      " .. (HOOKS.silent and "installed" or "NOT installed - needs the FFlag"),
				"target    " .. STATE.silentTarget,
				"bent      " .. STATE.silentShots .. " bullets redirected",
				"packets   " .. (HOOKS.sentBent or 0) .. " sent with the new direction",
				"confirms  " .. STATE.snapHits .. " hits the server accepted",
				"of those  " .. STATE.snapPartHits .. " counted as headshots",
			}, "\n"))

			moveOut:set(table.concat({
				string.format("speed     %.1f studs/s", STATE.speed),
				"multiplier " .. (CONFIG.speed and ("x" .. CONFIG.speedMult) or "off"),
				"character " .. (characterObject() and "reachable" or "not reachable")
					.. (CONFIG.fly and string.format("   fly %.0f studs up, %d keys, %d frames",
						STATE.flyAlt or 0, STATE.flyKeys or 0, STATE.flyFrames or 0) or ""),
			}, "\n"))

			local hud = hudRead()
			STATE.hud = hud and (hud.hp .. " hp") or "-"
			roundOut:set(table.concat({
				"mode      " .. (hud and hud.mode or "-"),
				"timer     " .. (hud and hud.timer or "-"),
				"health    " .. (hud and hud.hp or "-"),
				"ammo      " .. (hud and (hud.mag .. " / " .. hud.spare) or "-"),
				"grenades  " .. (hud and hud.nade or "-"),
				"firemode  " .. (hud and hud.fire or "-"),
			}, "\n"))

			-- Top of each board. The scoreboard replicates for every player, so
			-- this is the one number a Phantom Forces player normally cannot see
			-- without opening the leaderboard mid-firefight.
			local rows = {}
			local list = {}
			for name, st in pairs(boardStat) do
				list[#list + 1] = { name = name, st = st, team = boardOf[name] or "?" }
			end
			table.sort(list, function(a, b) return a.st.score > b.st.score end)
			for i = 1, math.min(10, #list) do
				local e = list[i]
				rows[#rows + 1] = string.format("%-18s %-9s %3d/%-3d %6d",
					e.name:sub(1, 18), e.team:sub(1, 9), e.st.kills, e.st.deaths, e.st.score)
			end
			if #rows == 0 then rows[1] = "scoreboard not readable yet" end
			boardOut:set(table.concat(rows, "\n"))

			local lines = {
				"  place    Phantom Forces (" .. tostring(game.PlaceId) .. ")",
				"  drawing  " .. (HAS_DRAWING and "available" or "MISSING - no ESP"),
				"  mouse    " .. (moveMouse and "mousemoverel available"
					or "MISSING - camera path only"),
				"  click    " .. STATE.clickWay,
				"  bodies   " .. STATE.alive .. " read, " .. STATE.targets .. " drawn",
				"  churn    " .. STATE.churn .. " models/s rebuilt",
				"  delivery " .. STATE.deliver
					.. (STATE.stickPct >= 0
						and ("   camera writes survive " .. STATE.stickPct .. "%") or ""),
				string.format("  aim err  %.2f deg", STATE.aimErr),
				"  TEAMS",
			}
			for _, line in ipairs(STATE.chain) do
				lines[#lines + 1] = "    " .. line
			end
			if STATE.mouseSens > 0 then
				lines[#lines + 1] = string.format("  mouse    %.5f rad per unit",
					STATE.mouseSens)
			end
			if STATE.note ~= "" then lines[#lines + 1] = "  note     " .. STATE.note end
			diagOut:set(table.concat(lines, "\n"))

			win:SetStat(1, tostring(STATE.targets), "targets")
			win:SetStat(2, string.format("%.1f", STATE.aimErr), "aim err")
			win:SetStat(3, tostring(STATE.shots), "shots")
			win:SetStatus("PHANTOM FORCES   " .. STATE.targets .. " targets   "
				.. STATE.myTeam .. "   " .. (CONFIG.aim and ("aim " .. STATE.deliver)
					or "aim off"))
		end)
		if not ok then note("panel: " .. tostring(err)) end
		task.wait(0.35)
	end
end)

--------------------------------------------------------------------------------
-- debug handle
--------------------------------------------------------------------------------

_G.__SELPF_DBG = {
	CONFIG = CONFIG, STATE = STATE, PRESETS = PRESETS,
	modelInfo = modelInfo, healthOf = healthOf, footOf = footOf,
	readBoards = readBoards, evaluateTeams = evaluateTeams, isTarget = isTarget,
	eachTarget = eachTarget, pickTarget = pickTarget, aimPointOf = aimPointOf,
	visible = visible, screenBox = screenBox, renderPass = renderPass,
	aimPass = aimPass, deliverMode = deliverMode, underCrosshair = underCrosshair,
	pullTrigger = pullTrigger, probeClick = probeClick, hudRead = hudRead,
	syncMods = syncMods, installHooks = installHooks, MODS = MODS, HOOKS = HOOKS,
	heldWeapon = heldWeapon, predictPoint = predictPoint,
	boardOf = function() return boardOf end, folderTeam = function() return folderTeam end,
	drawn = drawn,
}

print("[selux phantom] gen " .. GEN .. " ready - RightShift for the panel")
