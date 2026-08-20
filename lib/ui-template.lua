--!nocheck
-- ui-template.lua  --  the Selux panel, v3
--
--   local UI   = loadstring(readfile("ui-template.lua"))()
--   local win  = UI.Window({ title = "SPEED", accentTitle = "MONKEY", subtitle = "seltonmt" })
--   local page = win:Page("FARM", UI.icon.bolt)
--   local card = page:Card("LOOP", 1)      -- 1 = left, 2 = right, 0 = full width
--   card:Toggle("Auto", CONFIG.auto, function(v) CONFIG.auto = v end, "hint")
--   local refresh = card:Stepper("Stage", getText, onStep)   -- returns a refresher
--   card:Slider("Rate", 2, 40, 12, function(v) ... end)
--   card:Dropdown("Mode", { "Fast", "Safe" }, "Fast", function(v) ... end)
--   card:Button("Unstuck", function() ... end, UI.theme.bad)
--   local out = card:Readout(12); out:set({ "STATUS", "  income 47.3K/s" })
--   win:SetStatus("213K wins   lvl 241   world 2")     -- the live status line
--
-- THE PUBLIC API IS UNCHANGED FROM v1 AND v2. Nineteen game scripts call it and
-- not one of them was touched for this redesign: UI.Window, win:Page/Refresh/
-- SetStatus/Destroy, page:Card, card:Toggle/Stepper/Slider/Dropdown/Button/
-- Label/Readout, and every UI.theme.* / UI.icon.* / UI.font.* key.
--
-- What changed is the whole look, from the Selux mockup:
--
--   * 820x582 instead of 920x580, radius 13. It reads as a tool, not a window.
--   * The 240px sidebar is gone. Navigation is a 46px ICON RAIL - the pages had
--     names AND icons before and the names were dead weight; the page name now
--     lives once, in the header, where you are already looking.
--   * A tinted STATUS STRIP under the header carries the master toggle and three
--     numbers. That is what you glance at while playing, so it sits above the
--     controls rather than inside them.
--   * Cards became BLOCKS: a bordered box with a header band (icon, mono caps
--     label, "3 / 3 an") and hairline-separated rows. The band is what makes a
--     group readable without the card needing a drop shadow.
--   * A DISCORD BAR is pinned above the footer. It is the only outbound link and
--     it is always visible.
--   * Palette is flat violet on near-black - #8b5cf6 on #0d0a14 - and the accent
--     is a single colour, not the v2 violet->cyan ramp. The ramp fought every
--     screenshot and made the good/warn/bad tones harder to read.
--
-- Roblox has no inline SVG, so the mockup's stroked icons stay single glyphs
-- (UI.icon). Sora/IBM Plex Mono do not exist either: GothamBold stands in for
-- headings, Gotham for body, Code for every number and mono label.

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TextService = game:GetService("TextService")
local HttpService = game:GetService("HttpService")

local plr = Players.LocalPlayer

local UI = {}

UI.VERSION = "3.0"
UI.BRAND = "SELUX"
UI.DISCORD = "discord.gg/ARdpzFuKMm"
UI.REPO = "seltonmt012/sel01-rbx"

-- Where a "this is broken" report goes. EMPTY means the panel falls back to the
-- clipboard, which needs no infrastructure at all - so the button works from day
-- one and switching to the relay later is this one line, not a re-push of every
-- script.
--
-- It must NOT be a Discord webhook. These scripts are public on GitHub, webhook
-- URLs are scraped out of public repos by bots, and a webhook lets whoever finds
-- it post arbitrary content - images, links, @everyone - straight into the
-- channel. The only cure would be deleting the webhook and republishing all 21
-- scripts. A small relay in front of it does not hide the URL (nothing can) but
-- it turns the open letterbox into a form: it accepts a fixed set of fields,
-- writes the Discord message itself, rate-limits per IP, and can be changed in
-- one place in seconds without touching a single script.
UI.REPORT_URL = "https://selux-report.selux.workers.dev"

-- Palette ---------------------------------------------------------------------
-- Four depths, not five. v2 had void/rail/sidebar/window/header/subBar/card and
-- the difference between several of them was invisible on a real screen; this
-- keeps only the steps that actually separate something.
UI.theme = {
	void = Color3.fromHex("07050d"),
	rail = Color3.fromHex("0b0812"),
	sidebar = Color3.fromHex("0b0812"),   -- kept: v1 scripts may read it
	window = Color3.fromHex("0d0a14"),
	header = Color3.fromHex("0d0a14"),
	subBar = Color3.fromHex("120e1c"),
	card = Color3.fromHex("0f0c17"),
	cardHover = Color3.fromHex("141020"),
	input = Color3.fromHex("131020"),
	backdrop = Color3.fromHex("07050d"),

	band = Color3.fromHex("241f33"),      -- block border
	line = Color3.fromHex("1d182b"),      -- hairline between rows
	edge = Color3.fromHex("221c33"),      -- window border

	-- one accent, no ramp
	accent = Color3.fromHex("8b5cf6"),
	accentAlt = Color3.fromHex("a78bfa"),  -- kept for v1 callers; now just the hover
	accentHover = Color3.fromHex("a78bfa"),
	accentSoft = Color3.fromHex("c4b5fd"),

	discord = Color3.fromHex("5865f2"),
	discordAlt = Color3.fromHex("4650e0"),

	good = Color3.fromHex("5eead4"),
	warn = Color3.fromHex("fbbf24"),
	bad = Color3.fromHex("fb7185"),

	text = Color3.fromHex("efedf7"),
	textSoft = Color3.fromHex("e8e6f0"),
	muted = Color3.fromHex("a49cba"),
	dim = Color3.fromHex("8b839f"),
	dimmer = Color3.fromHex("6f6885"),
	faint = Color3.fromHex("5e5877"),
	fainter = Color3.fromHex("4b4468"),

	lineAlpha = 0.9,
	dimAlpha = 0.5,
	fainterAlpha = 0.7,
}

UI.font = {
	heading = Enum.Font.GothamBold,
	body = Enum.Font.Gotham,
	mono = Enum.Font.Code,
}

-- Every key from v1/v2 is still here; scripts index these by name and a missing
-- one would silently draw nothing.
--
-- EVERY GLYPH BELOW WAS RENDERED IN-GAME AND READ OFF A SCREENSHOT. Roblox's
-- Gotham does not have the whole Unicode symbol range and a missing glyph draws
-- as a tofu box, not as nothing - so v2's ⊞ ⌂ ⌕ ▾ ▣ ◷ ✦ ✧ ❉ ↻ ◍ ≡ all showed up
-- as ▯ in the panel. Verified working: ★ ☆ ◆ ◇ ● ○ ■ □ ▲ ▼ ⚡ ⚙ ▤ ▦ ↑ ↓ → ← ≈ ∞
-- ◉ ◎ ◊ ◈ ⛏ • ◦. Emoji render too, but in full colour, which fights a monochrome
-- rail - so they are not used. Duplicates below are deliberate: a repeated shape
-- beats a box.
UI.icon = {
	sliders = "▤", eye = "◉", target = "◎", shield = "◇",
	bolt = "⚡", gear = "⚙", list = "▤", chart = "▦",
	sword = "◆", coin = "●", flask = "◊", map = "◈",
	pickaxe = "⛏", bag = "■", clock = "○", flame = "◆",
	star = "★", wave = "≈", grid = "▦", spark = "★",
	home = "▲", loop = "→", up = "↑", info = "○",
}

-- ...and the real thing. The glyphs above are only the fallback now: a stroked
-- PNG set is rendered by tools/brand-render.py out of tools/brand/icons.html and
-- mirrored into the workspace, where getcustomasset() can reach it. A house that
-- looks like a house beats a filled circle standing in for one.
--
-- The map is keyed by the GLYPH because that is what scripts pass around
-- (page:Card / win:Page take UI.icon.bolt, a string). Several keys share a
-- glyph, so they share a file - deliberate, and better than a mismatch.
UI.iconFile = {
	["▲"] = "home", ["⚡"] = "bolt", ["○"] = "clock", ["▦"] = "chart",
	["●"] = "coin", ["★"] = "star", ["⚙"] = "gear", ["→"] = "loop",
	["▤"] = "list", ["■"] = "bag", ["◇"] = "shield", ["◆"] = "sword",
	["⛏"] = "pickaxe", ["◊"] = "flask", ["◈"] = "map", ["◉"] = "shield",
	["◎"] = "shield",
}

-- Real images, not glyphs ------------------------------------------------------
--
-- getcustomasset() turns a file sitting in the executor's workspace folder into
-- an rbxassetid the UI can draw, with no upload to Roblox and no moderation
-- wait. That is the whole trick for getting the actual logo - and any future
-- icon set - into the panel instead of hunting for a Unicode character that
-- Gotham happens to have.
--
-- bridge.py mirrors brand/selux-mark.png into the workspace for exactly this.
-- Everything is guarded: a missing file, an executor without the function, or a
-- different name for it must fall back to the text glyph, never error.
local imageCache = {}
function UI.image(file)
	if imageCache[file] ~= nil then return imageCache[file] or nil end
	local resolver = getcustomasset or getsynasset or (syn and syn.getcustomasset)
	local exists = isfile and isfile(file)
	if not resolver or not exists then
		imageCache[file] = false
		return nil
	end
	local ok, id = pcall(resolver, file)
	imageCache[file] = (ok and id) or false
	return imageCache[file] or nil
end

-- Icons straight off a URL. ImageLabel.Image does NOT take a web address - it
-- only ever accepts an rbxassetid - so the trick is to download the bytes, drop
-- them in the workspace and hand THAT to getcustomasset. Once fetched the file
-- stays, so it costs one request ever, and a dead link or an executor without
-- writefile simply returns nil.
--
--   local id = UI.imageFromUrl("https://raw.githubusercontent.com/.../swords.png")
--   if id then someImageLabel.Image = id end
--
-- The practical use: put a PNG in the sel01-rbx repo next to the scripts, and
-- every panel can draw it without anybody uploading anything to Roblox.
function UI.imageFromUrl(url, name)
	name = name or ("selux-cache/" .. (string.match(url, "([%w%-_%.]+)%.png$") or
		tostring(#url)) .. ".png")
	if isfile and isfile(name) then return UI.image(name) end
	if not writefile then return nil end
	local ok, body = pcall(function() return game:HttpGet(url) end)
	if not ok or not body or #body < 8 then return nil end
	-- Confirm it really is a PNG before caching it: an HTML error page written to
	-- disk as .png would be cached forever and draw nothing.
	if string.sub(body, 2, 4) ~= "PNG" then return nil end
	local wrote = pcall(writefile, name, body)
	if not wrote then return nil end
	return UI.image(name)
end

UI.LOGO = "selux-mark.png"

--------------------------------------------------------------------------------
-- language
--------------------------------------------------------------------------------
-- Three languages, one dictionary, and NOT ONE LINE changed in any game script.
--
-- The trick is that every piece of text a panel shows already funnels through
-- two places: label() when it is created and setText() when it changes. Both
-- stamp the ORIGINAL string onto the instance as an attribute and display
-- UI.t(original). Switching language therefore does not need to know where a
-- string came from - it walks the ScreenGui, reads the attribute back and
-- re-renders. A script that passes "Auto rebirth" keeps passing "Auto rebirth"
-- forever; only the dictionary decides what the player reads.
--
-- Anything with no dictionary entry falls through unchanged, so a missing
-- translation is a mixed panel, never a blank one.
UI.LANGS = { "de", "en", "ru" }
UI.LANG_NAME = { de = "Deutsch", en = "English", ru = "Russkij" }
UI.RAW = "https://raw.githubusercontent.com/" .. UI.REPO .. "/main/"

local LANG_FILE = "selux-lang.txt"
local TEXT_ATTR = "SxText"
local HINT_ATTR = "SxHint"

-- The player's own Roblox language is the best default there is: a Russian
-- client gets Russian without touching anything. A saved choice always wins.
local function detectLang()
	local ok, id = pcall(function()
		return game:GetService("LocalizationService").RobloxLocaleId
	end)
	if ok and type(id) == "string" then
		local two = string.lower(string.sub(id, 1, 2))
		for _, l in ipairs(UI.LANGS) do
			if l == two then return l end
		end
	end
	return "en"
end

UI.lang = _G.__SEL_LANG
if not UI.lang and isfile and isfile(LANG_FILE) then
	local ok, saved = pcall(readfile, LANG_FILE)
	if ok and type(saved) == "string" then
		saved = string.lower((string.gsub(saved, "%s", "")))
		for _, l in ipairs(UI.LANGS) do
			if l == saved then UI.lang = saved end
		end
	end
end
UI.lang = UI.lang or detectLang()
_G.__SEL_LANG = UI.lang

-- One dictionary file per language, not one file with three fields per key: a
-- client only ever renders one language, and Cyrillic costs two bytes a
-- character, so the combined table was 121 KB against 44 for German alone.
--
-- Order: whatever is already loaded in this session, then the workspace copy
-- (bridge.py sync puts it there while developing), then the repo. Cached to disk
-- after the first download, so it costs one request ever.
_G.__SEL_I18N = _G.__SEL_I18N or {}
local dicts = _G.__SEL_I18N

local function dictionary(lang)
	lang = lang or UI.lang
	if dicts[lang] ~= nil then return dicts[lang] or nil end
	local name = "i18n-" .. lang .. ".lua"
	local body
	if isfile and isfile(name) then
		local ok, disk = pcall(readfile, name)
		if ok then body = disk end
	end
	if not body then
		local ok, web = pcall(function() return game:HttpGet(UI.RAW .. "lib/" .. name) end)
		if ok and type(web) == "string" and #web > 64 then
			body = web
			pcall(function() writefile(name, web) end)
		end
	end
	if body then
		local chunk = loadstring and loadstring(body, "=" .. name)
		local ok, loaded = pcall(chunk or function() end)
		if ok and type(loaded) == "table" then dicts[lang] = loaded end
	end
	-- false, not nil: a language with no file must not be looked up again on
	-- every single label. There are hundreds per panel.
	if dicts[lang] == nil then dicts[lang] = false end
	return dicts[lang] or nil
end

-- Translate. Leading and trailing spacing is preserved separately because a lot
-- of the status lines are built by concatenation and carry padding that is part
-- of the layout, not part of the sentence.
function UI.t(text)
	if type(text) ~= "string" or text == "" then return text end
	local d = dictionary()
	if not d then return text end
	local hit = d[text]
	if hit then return hit end
	local lead, core, tail = string.match(text, "^(%s*)(.-)(%s*)$")
	if core and core ~= text and core ~= "" then
		hit = d[core]
		if hit then return lead .. hit .. tail end
	end
	return text
end

-- Translate a template and fill it in one step. Sentences that carry a number
-- have to stay ONE dictionary key - split into fragments and concatenated, the
-- word order is frozen in German and no other language can be written properly.
function UI.tf(template, ...)
	local ok, out = pcall(string.format, UI.t(template), ...)
	return ok and out or template
end

-- Every .Text assignment in this file goes through here. Setting .Text directly
-- works but the string is then invisible to a language switch, so the label
-- freezes in whatever language it was born in.
local function setText(instance, text)
	text = (text == nil) and "" or tostring(text)
	pcall(function()
		instance:SetAttribute(TEXT_ATTR, text)
		instance:SetAttribute("SxFmt", nil)
	end)
	instance.Text = UI.t(text)
end
UI.setText = setText

-- Text that is part sentence, part number ("3 aktiv", "2 / 5 an"). Storing the
-- finished string would make it untranslatable, because "3 aktiv" is not a
-- dictionary key and never will be. So the TEMPLATE is what gets stamped on the
-- instance and the arguments ride along beside it; a language switch formats it
-- again in the new language.
local function setFmt(instance, template, ...)
	local args = { ... }
	for i = 1, #args do args[i] = tostring(args[i]) end
	pcall(function()
		instance:SetAttribute(TEXT_ATTR, nil)
		instance:SetAttribute("SxFmt", template)
		instance:SetAttribute("SxArgs", table.concat(args, "\1"))
	end)
	instance.Text = string.format(UI.t(template), table.unpack(args))
end
UI.setFmt = setFmt

local function applyFmt(instance)
	local template = instance:GetAttribute("SxFmt")
	if not template then return end
	local args = {}
	for piece in string.gmatch((instance:GetAttribute("SxArgs") or "") .. "\1", "([^\1]*)\1") do
		args[#args + 1] = piece
	end
	instance.Text = string.format(UI.t(template), table.unpack(args))
end

local function setPlaceholder(instance, text)
	text = (text == nil) and "" or tostring(text)
	pcall(function() instance:SetAttribute(HINT_ATTR, text) end)
	instance.PlaceholderText = UI.t(text)
end

-- Live windows, weak-keyed so a destroyed panel does not keep its ScreenGui
-- alive just because the language switch might want it later.
local liveWindows = setmetatable({}, { __mode = "k" })

local function retranslate(root)
	if not root or not root.Parent then return end
	for _, d in ipairs(root:GetDescendants()) do
		local t = d:GetAttribute(TEXT_ATTR)
		if t ~= nil then pcall(function() d.Text = UI.t(t) end) end
		if d:GetAttribute("SxFmt") ~= nil then pcall(applyFmt, d) end
		local h = d:GetAttribute(HINT_ATTR)
		if h ~= nil then pcall(function() d.PlaceholderText = UI.t(h) end) end
	end
end

function UI.setLang(code)
	local valid = false
	for _, l in ipairs(UI.LANGS) do
		if l == code then valid = true end
	end
	if not valid or code == UI.lang then return false end
	UI.lang = code
	_G.__SEL_LANG = code
	pcall(function() writefile(LANG_FILE, code) end)
	for window in pairs(liveWindows) do
		retranslate(window.gui)
		if window.onLang then pcall(window.onLang, code) end
	end
	return true
end

--------------------------------------------------------------------------------
-- device and scale
--------------------------------------------------------------------------------
--
-- The panel is 820x582 and that is a comfortable window on a monitor and the
-- ENTIRE SCREEN on a phone - people run these scripts on mobile executors and
-- the game underneath is then completely covered. So every window carries a
-- UIScale, the scale comes from the viewport, and the device is asked once and
-- remembered in selux-device.txt next to selux-lang.txt.
--
-- PC is deliberately left alone: the formula caps at 1, so a monitor of any
-- normal size renders exactly what it rendered before this existed.
local DEVICE_FILE = "selux-device.txt"
UI.DEVICES = { "pc", "mobile" }

-- Guarded to the last line: uitest.lua runs this file against a fake Roblox that
-- has no workspace and no camera at all, and a template that cannot be loaded
-- outside the game loses its only test harness.
function UI.viewport()
	-- Test hook: there is no way to give a desktop client a phone's viewport, so
	-- _G.__SEL_VIEWPORT forces one and the panel can be looked at at the size it
	-- would really have on a 844x390 phone. Never set in normal use.
	local forced = _G.__SEL_VIEWPORT
	if typeof and typeof(forced) == "Vector2" then return forced end
	local ok, size = pcall(function()
		local cam = workspace and workspace.CurrentCamera
		return cam and cam.ViewportSize
	end)
	if ok and size and size.X and size.X > 1 and size.Y > 1 then return size end
	return Vector2.new(1280, 720)
end

-- Touch WITHOUT a keyboard is a phone or a tablet; a touchscreen laptop reports
-- both and is a PC. The viewport is the second opinion, because an emulator or
-- a mobile executor that lies about TouchEnabled still cannot fake being 1080p.
function UI.detectDevice()
	local touch, keyboard, mouse = false, true, true
	pcall(function()
		local uis = game:GetService("UserInputService")
		touch, keyboard, mouse = uis.TouchEnabled, uis.KeyboardEnabled, uis.MouseEnabled
	end)
	local vp = UI.viewport()
	local vx = tonumber(vp.X) or 1280
	local vy = tonumber(vp.Y) or 720
	local size = math.floor(vx) .. "x" .. math.floor(vy)
	-- ORDER MATTERS, and getting it wrong is not theoretical: the viewport test
	-- came first in the first version and called a WINDOWED desktop client
	-- (958x599 here) a phone. A keyboard and a mouse together are a PC whatever
	-- the window size is, and the viewport is only the tie-breaker for a client
	-- that reports neither.
	if touch and not keyboard then return "mobile", "touch, no keyboard" end
	if keyboard and mouse then return "pc", "keyboard + mouse, " .. size end
	if vx < 900 or vy < 500 then return "mobile", "viewport " .. size end
	return "pc", size
end

UI.device = _G.__SEL_DEVICE
UI.deviceAsked = _G.__SEL_DEVICE_ASKED or false
if not UI.device and isfile and isfile(DEVICE_FILE) then
	local ok, saved = pcall(readfile, DEVICE_FILE)
	if ok and type(saved) == "string" then
		saved = string.lower((string.gsub(saved, "%s", "")))
		if saved == "pc" or saved == "mobile" then
			UI.device = saved
			UI.deviceAsked = true
		end
	end
end
local detected, detectWhy = UI.detectDevice()
UI.device = UI.device or detected
UI.detected, UI.detectWhy = detected, detectWhy
_G.__SEL_DEVICE = UI.device
_G.__SEL_DEVICE_ASKED = UI.deviceAsked

-- How much of the screen a panel is allowed to take. On a phone the point is
-- that the GAME stays visible, so it is capped well below the full height; on a
-- desktop the cap of 1 means nothing changes at all.
UI.deviceFill = { pc = 0.98, mobile = 0.80 }

function UI.scaleFor(width, height)
	local vp = UI.viewport()
	local vx = tonumber(vp.X) or 1280
	local vy = tonumber(vp.Y) or 720
	local fill = UI.deviceFill[UI.device] or 0.98
	local s = math.min(vx * fill / math.max(width, 1), vy * fill / math.max(height, 1), 1)
	return math.max(s, 0.3)
end

-- Live windows register a rescale hook, so switching the device moves every open
-- panel at once - exactly like the language switch does.
local liveScales = setmetatable({}, { __mode = "k" })

function UI.setDevice(code, remember)
	if code ~= "pc" and code ~= "mobile" then return false end
	UI.device = code
	_G.__SEL_DEVICE = code
	if remember ~= false then
		UI.deviceAsked = true
		_G.__SEL_DEVICE_ASKED = true
		pcall(function() writefile(DEVICE_FILE, code) end)
	end
	for window in pairs(liveScales) do
		pcall(function() window.applyScale() end)
	end
	return true
end

-- The flag itself: the repo copy for everybody, the workspace copy while
-- developing, and the two letters when neither is reachable. A panel must never
-- lose its language switch because an image did not load.
local flagCache = {}
function UI.flag(code)
	if flagCache[code] ~= nil then return flagCache[code] or nil end
	local id = UI.image("icons/selux-flag-" .. code .. ".png")
	if not id then id = UI.imageFromUrl(UI.RAW .. "flags/" .. code .. ".png",
		"selux-cache/flag-" .. code .. ".png") end
	flagCache[code] = id or false
	return id
end


local EASE = {
	quick = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
	soft = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
	snap = TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
	slow = TweenInfo.new(0.3, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
	rise = TweenInfo.new(0.5, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
}

--------------------------------------------------------------------------------
-- helpers
--------------------------------------------------------------------------------

local function tween(instance, info, props)
	local t = TweenService:Create(instance, info, props)
	t:Play()
	return t
end

local function corner(instance, radius)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius or 9)
	c.Parent = instance
	return c
end

local function stroke(instance, color, alpha, thickness)
	local s = Instance.new("UIStroke")
	s.Color = color or UI.theme.band
	s.Transparency = alpha or 0
	s.Thickness = thickness or 1
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = instance
	return s
end

local function pad(instance, l, r, t, b)
	local p = Instance.new("UIPadding")
	p.PaddingLeft = UDim.new(0, l or 0)
	p.PaddingRight = UDim.new(0, r or l or 0)
	p.PaddingTop = UDim.new(0, t or 0)
	p.PaddingBottom = UDim.new(0, b or t or 0)
	p.Parent = instance
	return p
end

local function listLayout(parent, gap, dir)
	local l = Instance.new("UIListLayout")
	l.FillDirection = dir or Enum.FillDirection.Vertical
	l.SortOrder = Enum.SortOrder.LayoutOrder
	l.Padding = UDim.new(0, gap or 0)
	l.Parent = parent
	return l
end

local function frame(parent, size, position, color, transparency)
	local f = Instance.new("Frame")
	f.Size = size or UDim2.fromScale(1, 1)
	f.Position = position or UDim2.fromOffset(0, 0)
	f.BackgroundColor3 = color or UI.theme.window
	f.BackgroundTransparency = transparency or 0
	f.BorderSizePixel = 0
	f.Parent = parent
	return f
end

local function label(parent, text, size, font, color, alpha)
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	setText(l, text)
	l.TextSize = size or 12
	l.Font = font or UI.font.body
	l.TextColor3 = color or UI.theme.textSoft
	l.TextTransparency = alpha or 0
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextYAlignment = Enum.TextYAlignment.Center
	l.RichText = true
	l.Parent = parent
	return l
end

-- A hairline. Roblox rounds a 1px frame away at some resolutions if it is given
-- a scale height, so these are always offset-sized.
local function hairline(parent, inset, color)
	local h = frame(parent, UDim2.new(1, -(inset or 0) * 2, 0, 1),
		UDim2.fromOffset(inset or 0, 0), color or UI.theme.line)
	return h
end

-- Draw an icon into `parent`: an ImageLabel if the PNG is there, a TextLabel
-- with the glyph if it is not. Returns the instance plus a tint(colour) function,
-- so the caller does not have to care which of the two it got - the rail tints
-- the active page and the card bands tint themselves the same way.
-- Scripts call these setters with a COLON (weaponLabel:set(x), out:set(lines)),
-- which passes the wrapper table as the first argument and the real value as the
-- second. Written as set(value) the value silently becomes the table and the
-- control either shows nothing or errors - it cost a blank read-out in every
-- panel and a broken weapon line in lootevo. arg() takes both call styles.
local function arg(a, b)
	if b ~= nil then return b end
	if type(a) == "table" and (a.set ~= nil or a.get ~= nil) then return nil end
	return a
end

local function iconNode(parent, glyph, size, colour)
	local file = UI.iconFile[glyph]
	local id = file and UI.image("icons/selux-" .. file .. ".png") or nil
	if id then
		local img = Instance.new("ImageLabel")
		img.BackgroundTransparency = 1
		img.Image = id
		img.ImageColor3 = colour or UI.theme.dimmer
		img.ScaleType = Enum.ScaleType.Fit
		img.Size = UDim2.fromOffset(size, size)
		img.Parent = parent
		return img, function(c) img.ImageColor3 = c end
	end
	local l = label(parent, glyph or "", size, UI.font.body, colour or UI.theme.dimmer)
	l.Size = UDim2.fromOffset(size + 4, size + 4)
	l.TextXAlignment = Enum.TextXAlignment.Center
	return l, function(c) l.TextColor3 = c end
end

-- The mockup's `rise` keyframe: fade in and lift 14px. Used on every block so a
-- page change reads as content arriving rather than as a redraw.
local function rise(instance, delay)
	local goalPos = instance.Position
	instance.Position = goalPos + UDim2.fromOffset(0, 14)
	for _, d in ipairs(instance:GetDescendants()) do
		if d:IsA("TextLabel") or d:IsA("TextButton") then
			d.TextTransparency = 1
		end
	end
	instance.BackgroundTransparency = 1
	task.delay(delay or 0, function()
		if not instance.Parent then return end
		tween(instance, EASE.rise, { Position = goalPos, BackgroundTransparency = 0 })
		for _, d in ipairs(instance:GetDescendants()) do
			if d:IsA("TextLabel") or d:IsA("TextButton") then
				tween(d, EASE.rise, { TextTransparency = 0 })
			end
		end
	end)
end

-- One shared Heartbeat drives every pulsing dot. A RunService connection per
-- element is what turns a Roblox panel into a stutter; this was measured at 59
-- FPS with sixteen live elements in v2 and the same driver is kept.
local pulses, pulseConn = {}, nil
local function registerPulse(instance, period, lo, hi)
	pulses[instance] = { period = period or 2.2, lo = lo or 0.65, hi = hi or 0 }
	if pulseConn then return end
	pulseConn = RunService.Heartbeat:Connect(function()
		local t = os.clock()
		local live = false
		for inst, cfg in pairs(pulses) do
			if inst.Parent then
				live = true
				local a = (math.sin(t * math.pi * 2 / cfg.period) + 1) / 2
				inst.BackgroundTransparency = cfg.hi + (cfg.lo - cfg.hi) * a
			else
				pulses[inst] = nil
			end
		end
		if not live then
			pulseConn:Disconnect()
			pulseConn = nil
		end
	end)
end

-- v2 exposed registerSpin for rotating accent gradients. The v3 accent is flat,
-- but a script may still call it, so it stays as a no-op-safe shim.
local function registerSpin(gradient)
	if gradient then gradient.Rotation = 0 end
end

local function press(button, color)
	-- A sibling flash, never a colour tween on the button itself: tweening the
	-- fill fights the hover tween and the two cancel each other mid-click.
	local flash = frame(button, UDim2.fromScale(1, 1), nil, color or Color3.new(1, 1, 1), 0.8)
	flash.ZIndex = button.ZIndex + 3
	corner(flash, 8)
	tween(flash, EASE.soft, { BackgroundTransparency = 1 })
	task.delay(0.2, function() flash:Destroy() end)
end

--------------------------------------------------------------------------------
-- the device question
--------------------------------------------------------------------------------
--
-- Asked ONCE, the first time any panel is built on this executor, and then never
-- again - the answer lives in selux-device.txt. It is deliberately a tiny card
-- and not a full-screen dialog: the whole point of the question is that a
-- full-screen anything is unusable on a phone, so the question itself must not
-- be one. The detected answer is pre-selected, so on a desktop it is one click
-- (or no click at all - the panel is already correct behind it).
function UI.askDevice(onDone)
	if UI.deviceGui and UI.deviceGui.Parent then return UI.deviceGui end

	local W, H = 300, 186
	local gui = Instance.new("ScreenGui")
	gui.Name = "SeluxDevice"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = 1000
	pcall(function() gui.Parent = game:GetService("CoreGui") end)
	if not gui.Parent then gui.Parent = plr:WaitForChild("PlayerGui") end
	UI.deviceGui = gui

	local card = frame(gui, UDim2.fromOffset(W, H), nil, UI.theme.window)
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Position = UDim2.fromScale(0.5, 0.5)
	card.Active = true
	card.Draggable = true
	corner(card, 13)
	stroke(card, UI.theme.accent, 0.4)
	local cardScale = Instance.new("UIScale")
	cardScale.Scale = UI.scaleFor(W, H)
	cardScale.Parent = card

	local title = label(card, UI.BRAND, 13, UI.font.heading, UI.theme.accentSoft)
	title.Position = UDim2.fromOffset(16, 12)
	title.Size = UDim2.fromOffset(120, 16)

	local question = label(card, "Panel-Groesse: PC oder Handy?", 14, UI.font.heading, UI.theme.text)
	question.Position = UDim2.fromOffset(16, 34)
	question.Size = UDim2.new(1, -32, 0, 20)

	local hint = label(card, "Auf dem Handy wird das Panel kleiner skaliert, damit das Spiel sichtbar bleibt.",
		11, UI.font.body, UI.theme.muted)
	hint.Position = UDim2.fromOffset(16, 56)
	hint.Size = UDim2.new(1, -32, 0, 30)
	hint.TextWrapped = true
	hint.TextYAlignment = Enum.TextYAlignment.Top

	local found = label(card, "", 10, UI.font.body, UI.theme.faint)
	found.Position = UDim2.fromOffset(16, H - 26)
	found.Size = UDim2.new(1, -32, 0, 14)
	setText(found, "erkannt: " .. UI.detected .. " (" .. tostring(UI.detectWhy) .. ")")

	local buttons = {}
	local function paint()
		for code, b in pairs(buttons) do
			local on = (code == UI.device)
			tween(b.button, EASE.quick, {
				BackgroundColor3 = on and UI.theme.accent or UI.theme.input,
				BackgroundTransparency = on and 0 or 0.25,
			})
			tween(b.text, EASE.quick, { TextColor3 = on and UI.theme.window or UI.theme.textSoft })
		end
	end

	local labels = { pc = "PC", mobile = "Handy" }
	for i, code in ipairs(UI.DEVICES) do
		-- 128x40 is a finger, not a mouse pointer: anything smaller is a miss on a
		-- phone, which is precisely the device this question exists for.
		local b = Instance.new("TextButton")
		b.Size = UDim2.fromOffset(128, 40)
		b.Position = UDim2.fromOffset(16 + (i - 1) * 140, 96)
		b.BackgroundColor3 = UI.theme.input
		b.BorderSizePixel = 0
		b.Text = ""
		b.AutoButtonColor = false
		b.Parent = card
		corner(b, 9)
		local text = label(b, labels[code] or code, 14, UI.font.heading, UI.theme.textSoft)
		text.Size = UDim2.fromScale(1, 1)
		text.TextXAlignment = Enum.TextXAlignment.Center
		buttons[code] = { button = b, text = text }
		-- task.delay rather than task.wait: the handler must not yield. A real tap
		-- would survive it, but a synthetic con:Fire() runs the body inline and
		-- died on "thread is not yieldable", which left the card on screen with
		-- the choice already saved - the one state that looks broken to a user.
		b.MouseButton1Click:Connect(function()
			UI.setDevice(code)
			paint()
			UI.deviceGui = nil
			task.delay(0.15, function() pcall(function() gui:Destroy() end) end)
			if onDone then pcall(onDone, code) end
		end)
	end
	paint()
	return gui
end

--------------------------------------------------------------------------------
-- window
--------------------------------------------------------------------------------

function UI.Window(options)
	options = options or {}
	local width = options.width or 820
	local height = options.height or 582
	local window = {}

	local gui = Instance.new("ScreenGui")
	gui.Name = options.name or ("Selux_" .. tostring(math.random(1e5, 1e6)))
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = 999
	pcall(function() gui.Parent = game:GetService("CoreGui") end)
	if not gui.Parent then gui.Parent = plr:WaitForChild("PlayerGui") end
	window.gui = gui

	local root = Instance.new("Frame")
	root.Size = UDim2.fromOffset(width, height)
	root.Position = UDim2.new(0.5, -width / 2, 0.5, -height / 2)
	-- Everything below is laid out in offsets against 820x582, and rewriting all
	-- of it in scale units would break every measured position in this file. One
	-- UIScale on the root does the whole job instead: it multiplies the rendered
	-- size of the frame and every descendant, about the AnchorPoint - which is
	-- (0,0) here, so the position has to be recentred by hand whenever it changes.
	local rootScale = Instance.new("UIScale")
	rootScale.Scale = 1
	rootScale.Parent = root

	-- THE QUESTION COMES FIRST. Building the panel and showing the card on top of
	-- it means a phone sees the full-screen panel it was about to fix, so the
	-- window is built - the script keeps adding pages to it as usual - and simply
	-- stays hidden until the device is known. It is revealed at the right scale,
	-- so a phone never renders a desktop-sized panel for even one frame.
	local pendingDevice = not UI.deviceAsked
	if pendingDevice then root.Visible = false end
	root.BackgroundColor3 = UI.theme.window
	root.BorderSizePixel = 0
	root.Active = true
	root.Draggable = true
	root.ClipsDescendants = true
	root.Parent = gui
	corner(root, 13)
	stroke(root, UI.theme.edge, 0)
	window.root = root

	-- drop shadow: box-shadow 0 26px 60px rgba(0,0,0,.65)
	local shadow = Instance.new("ImageLabel")
	shadow.BackgroundTransparency = 1
	shadow.Image = "rbxassetid://1316045217"
	shadow.ImageColor3 = Color3.new(0, 0, 0)
	shadow.ImageTransparency = 0.35
	shadow.ScaleType = Enum.ScaleType.Slice
	shadow.SliceCenter = Rect.new(10, 10, 118, 118)
	shadow.Size = UDim2.new(1, 60, 1, 60)
	shadow.Position = UDim2.fromOffset(-30, -4)
	shadow.ZIndex = 0
	shadow.Parent = root

	----------------------------------------------------------------- icon rail
	local rail = frame(root, UDim2.new(0, 46, 1, 0), nil, UI.theme.rail)
	rail.ZIndex = 2
	local railEdge = frame(rail, UDim2.new(0, 1, 1, 0), UDim2.new(1, -1, 0, 0), UI.theme.line)
	railEdge.ZIndex = 3

	-- The real mark if it is on disk, the violet tile with a letter if it is not.
	-- The PNG is the outlined hex on transparent, so it wants the rail's own dark
	-- background behind it - putting it on the violet tile kills the contrast.
	local logoId = UI.image(options.logo or UI.LOGO)
	local badge, badgeText
	if logoId then
		badge = Instance.new("ImageLabel")
		badge.Size = UDim2.fromOffset(28, 28)
		badge.Position = UDim2.fromOffset(9, 10)
		badge.BackgroundTransparency = 1
		badge.Image = logoId
		badge.ScaleType = Enum.ScaleType.Fit
		badge.ZIndex = 3
		badge.Parent = rail
	else
		badge = frame(rail, UDim2.fromOffset(26, 26), UDim2.fromOffset(10, 11), UI.theme.accent)
		badge.ZIndex = 3
		corner(badge, 8)
		badgeText = label(badge, options.badge or "S", 14, UI.font.heading, UI.theme.window)
		badgeText.Size = UDim2.fromScale(1, 1)
		badgeText.TextXAlignment = Enum.TextXAlignment.Center
		badgeText.ZIndex = 4
	end

	-- The device question has to be reachable again after it has been answered -
	-- a phone that was answered "PC" by accident would otherwise be stuck with a
	-- panel covering the whole screen and no way back. The mark in the rail is
	-- the button; there is no room in the header for another chip and the mark is
	-- the one element every panel has in the same place.
	local badgeHit = Instance.new("TextButton")
	badgeHit.Size = UDim2.fromOffset(34, 34)
	badgeHit.Position = UDim2.fromOffset(6, 7)
	badgeHit.BackgroundTransparency = 1
	badgeHit.Text = ""
	badgeHit.AutoButtonColor = false
	badgeHit.ZIndex = 5
	badgeHit.Parent = rail
	badgeHit.MouseButton1Click:Connect(function() pcall(UI.askDevice) end)

	local railList = frame(rail, UDim2.new(1, 0, 1, -100), UDim2.fromOffset(0, 46), UI.theme.rail, 1)
	railList.ZIndex = 3
	local railLayout = listLayout(railList, 6)
	railLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center

	----------------------------------------------------------------- content
	local content = frame(root, UDim2.new(1, -46, 1, 0), UDim2.fromOffset(46, 0), UI.theme.window)
	content.ZIndex = 1

	-- header, 38px
	local head = frame(content, UDim2.new(1, 0, 0, 38), nil, UI.theme.header)
	head.ZIndex = 2
	hairline(head, 0, UI.theme.edge).Position = UDim2.new(0, 0, 1, -1)

	local brand = label(head, UI.BRAND, 13, UI.font.heading, UI.theme.textSoft)
	brand.Position = UDim2.fromOffset(14, 0)
	brand.Size = UDim2.fromOffset(48, 38)
	brand.ZIndex = 3

	local brandDiv = frame(head, UDim2.fromOffset(1, 13), UDim2.fromOffset(66, 13), UI.theme.band)
	brandDiv.ZIndex = 3

	local pageName = label(head, options.title or "Panel", 13, UI.font.body, UI.theme.muted)
	pageName.Position = UDim2.fromOffset(76, 0)
	pageName.Size = UDim2.fromOffset(110, 38)
	pageName.ZIndex = 3
	window.pageName = pageName

	local headSub = label(head, options.subtitle or "", 11, UI.font.body, UI.theme.faint)
	headSub.Position = UDim2.fromOffset(190, 0)
	headSub.Size = UDim2.fromOffset(120, 38)
	headSub.ZIndex = 3
	window.headSub = headSub

	-- search sits in the middle of the header, like the mockup
	-- Drawn as a real field. It used to be fully transparent with no outline, so
	-- the placeholder floated in the header and there was no telling where the
	-- box began or ended.
	local searchWrap = frame(head, UDim2.fromOffset(172, 24), UDim2.new(1, -368, 0, 7),
		UI.theme.input, 0)
	searchWrap.ZIndex = 3
	corner(searchWrap, 7)
	local searchEdge = stroke(searchWrap, UI.theme.band, 0)
	pad(searchWrap, 10, 10, 0, 0)
	-- No magnifier glyph: Roblox draws ⌕ as a tofu box. The placeholder says
	-- "Suche" and that is enough - a box that means nothing is worse than no icon.
	local search = Instance.new("TextBox")
	search.BackgroundTransparency = 1
	search.Position = UDim2.fromOffset(0, 0)
	search.Size = UDim2.new(1, 0, 1, 0)
	search.Text = ""
	setPlaceholder(search, "Suche")
	search.TextSize = 12
	search.Font = UI.font.body
	search.TextColor3 = UI.theme.textSoft
	search.PlaceholderColor3 = UI.theme.faint
	search.TextXAlignment = Enum.TextXAlignment.Left
	search.ClearTextOnFocus = false
	search.ZIndex = 4
	search.Parent = searchWrap
	search.Focused:Connect(function()
		tween(searchEdge, EASE.quick, { Color = UI.theme.accent })
	end)
	search.FocusLost:Connect(function()
		tween(searchEdge, EASE.quick, { Color = UI.theme.band })
	end)

	local activeCount = label(head, "0 aktiv", 11, UI.font.body, UI.theme.accentSoft)
	activeCount.Position = UDim2.new(1, -186, 0, 0)
	activeCount.Size = UDim2.fromOffset(60, 38)
	activeCount.TextXAlignment = Enum.TextXAlignment.Right
	activeCount.ZIndex = 3
	window.activeCount = activeCount

	-- 20x20 is a mouse target. On a phone the panel is scaled to about half, so
	-- the same button lands near 10 points across - smaller than a fingertip and
	-- effectively unpressable. The background is transparent and the glyph is
	-- centred, so growing the button only grows what can be hit.
	local headHit = (UI.device == "mobile") and 30 or 20
	local function headButton(text, offset, onClick)
		local b = Instance.new("TextButton")
		b.Size = UDim2.fromOffset(headHit, headHit)
		b.Position = UDim2.new(1, offset - (headHit - 20) / 2, 0, 9 - (headHit - 20) / 2)
		b.BackgroundColor3 = Color3.new(1, 1, 1)
		b.BackgroundTransparency = 1
		b.BorderSizePixel = 0
		b.Text = text
		b.TextSize = 12
		b.Font = UI.font.heading
		b.TextColor3 = UI.theme.dimmer
		b.AutoButtonColor = false
		b.ZIndex = 3
		b.Parent = head
		corner(b, 6)
		b.MouseEnter:Connect(function()
			tween(b, EASE.quick, { BackgroundTransparency = 0.93, TextColor3 = UI.theme.textSoft })
		end)
		b.MouseLeave:Connect(function()
			tween(b, EASE.quick, { BackgroundTransparency = 1, TextColor3 = UI.theme.dimmer })
		end)
		b.MouseButton1Click:Connect(onClick)
		return b
	end

	----------------------------------------------------------------- language
	-- Three flags in the header, left of the window buttons. Deliberately not a
	-- dropdown: one click has to be enough, and a menu would need a label, which
	-- would itself need translating before anyone can read it.
	local flagStrip = frame(head, UDim2.fromOffset(66, 38), UDim2.new(1, -118, 0, 0),
		UI.theme.header, 1)
	flagStrip.ZIndex = 3
	local flagChips = {}

	-- The chip is either an ImageLabel or a TextLabel, and TweenService throws on
	-- a property the instance does not have - so each chip carries its own fade
	-- rather than the loop guessing which one it got.
	local function paintFlags()
		for code, chip in pairs(flagChips) do
			local on = (code == UI.lang)
			chip.fade(on and 0 or 0.55)
			tween(chip.edge, EASE.quick, {
				Color = on and UI.theme.accent or UI.theme.band,
				Transparency = on and 0 or 0.4,
			})
		end
	end

	for i, code in ipairs(UI.LANGS) do
		local chip = Instance.new("TextButton")
		chip.Size = UDim2.fromOffset(19, 14)
		chip.Position = UDim2.fromOffset((i - 1) * 23, 12)
		chip.BackgroundColor3 = UI.theme.input
		chip.BackgroundTransparency = 0.35
		chip.BorderSizePixel = 0
		chip.Text = ""
		chip.AutoButtonColor = false
		chip.ZIndex = 3
		chip.Parent = flagStrip
		corner(chip, 3)
		local edge = stroke(chip, UI.theme.band, 0.4)

		-- The image if it is reachable, the two letters if it is not. A panel
		-- must never lose its language switch because a PNG did not download.
		local fade
		local flagId = UI.flag(code)
		if flagId then
			local art = Instance.new("ImageLabel")
			art.BackgroundTransparency = 1
			art.Image = flagId
			art.ScaleType = Enum.ScaleType.Crop
			art.Size = UDim2.fromScale(1, 1)
			art.ZIndex = 4
			art.Parent = chip
			corner(art, 3)
			fade = function(a) tween(art, EASE.quick, { ImageTransparency = a }) end
		else
			-- The two letters are NOT translated: "DE" has to stay "DE" in every
			-- language or the switch stops being a switch.
			local art = Instance.new("TextLabel")
			art.BackgroundTransparency = 1
			art.Text = string.upper(code)
			art.TextSize = 9
			art.Font = UI.font.heading
			art.TextColor3 = UI.theme.textSoft
			art.Size = UDim2.fromScale(1, 1)
			art.ZIndex = 4
			art.Parent = chip
			fade = function(a) tween(art, EASE.quick, { TextTransparency = a }) end
		end
		flagChips[code] = { chip = chip, fade = fade, edge = edge }

		chip.MouseEnter:Connect(function()
			if code ~= UI.lang then fade(0.15) end
		end)
		chip.MouseLeave:Connect(paintFlags)
		chip.MouseButton1Click:Connect(function()
			if UI.setLang(code) then paintFlags() end
		end)
	end
	paintFlags()
	window.paintFlags = paintFlags
	-- A switch in one panel has to move every panel that is open, so the window
	-- registers itself and UI.setLang calls back into it.
	window.onLang = paintFlags
	liveWindows[window] = true

	----------------------------------------------------------------- scale
	-- Recentres as well as resizes: with AnchorPoint (0,0) a UIScale shrinks the
	-- panel towards its top-left corner, so a scaled window left at the old
	-- position sits high and to the left of centre instead of in the middle.
	function window.applyScale(value)
		local s = value or UI.scaleFor(width, height)
		rootScale.Scale = s
		root.Position = UDim2.new(0.5, -(width * s) / 2, 0.5, -(height * s) / 2)
		window.scale = s
		return s
	end
	liveScales[window] = true
	window.applyScale()
	-- A phone has no RightShift, so the hotkey below cannot bring a hidden panel
	-- back. The pill does, and it only exists where it is needed.
	local reopen = Instance.new("TextButton")
	reopen.Name = "SeluxReopen"
	reopen.Size = UDim2.fromOffset(74, 30)
	reopen.Position = UDim2.new(0, 12, 0, 12)
	reopen.BackgroundColor3 = UI.theme.accent
	reopen.BorderSizePixel = 0
	reopen.Text = ""
	reopen.AutoButtonColor = false
	reopen.Visible = false
	reopen.Active = true
	reopen.Draggable = true
	reopen.ZIndex = 50
	reopen.Parent = gui
	corner(reopen, 9)
	local reopenText = label(reopen, UI.BRAND, 12, UI.font.heading, UI.theme.window)
	reopenText.Size = UDim2.fromScale(1, 1)
	reopenText.TextXAlignment = Enum.TextXAlignment.Center
	reopenText.ZIndex = 51
	reopen.MouseButton1Click:Connect(function()
		root.Visible = true
		reopen.Visible = false
	end)
	window.reopen = reopen
	root:GetPropertyChangedSignal("Visible"):Connect(function()
		reopen.Visible = (not root.Visible) and UI.device == "mobile"
	end)

	----------------------------------------------------------------- status strip
	local strip = frame(content, UDim2.new(1, 0, 0, 52), UDim2.fromOffset(0, 38), UI.theme.accent, 0.95)
	strip.ZIndex = 2
	hairline(strip, 0, UI.theme.edge).Position = UDim2.new(0, 0, 1, -1)
	window.strip = strip

	local stripToggle = frame(strip, UDim2.fromOffset(34, 19), UDim2.fromOffset(15, 17), UI.theme.band)
	stripToggle.ZIndex = 3
	corner(stripToggle, 10)
	local stripKnob = frame(stripToggle, UDim2.fromOffset(13, 13), UDim2.fromOffset(3, 3),
		UI.theme.fainter)
	stripKnob.ZIndex = 4
	corner(stripKnob, 7)
	local stripHit = Instance.new("TextButton")
	stripHit.Size = UDim2.fromScale(1, 1)
	stripHit.BackgroundTransparency = 1
	stripHit.Text = ""
	stripHit.ZIndex = 5
	stripHit.Parent = stripToggle

	local stripTitle = label(strip, "Bereit", 14, UI.font.heading, UI.theme.text)
	stripTitle.Position = UDim2.fromOffset(63, 12)
	stripTitle.Size = UDim2.fromOffset(240, 14)
	stripTitle.ZIndex = 3
	window.stripTitle = stripTitle

	local stripSub = label(strip, options.subtitle or "", 11, UI.font.mono, UI.theme.dimmer)
	stripSub.Position = UDim2.fromOffset(63, 28)
	stripSub.Size = UDim2.fromOffset(300, 12)
	stripSub.ZIndex = 3
	window.stripSub = stripSub

	-- three stat columns on the right
	local stats = {}
	local statHolder = frame(strip, UDim2.fromOffset(240, 52), UDim2.new(1, -255, 0, 0),
		UI.theme.window, 1)
	statHolder.ZIndex = 3
	local statLayout = listLayout(statHolder, 20, Enum.FillDirection.Horizontal)
	statLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	statLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	for i = 1, 3 do
		local col = frame(statHolder, UDim2.fromOffset(70, 34), nil, UI.theme.window, 1)
		col.LayoutOrder = i
		col.ZIndex = 3
		local value = label(col, "-", 15, UI.font.mono,
			i == 2 and UI.theme.accentSoft or UI.theme.text)
		value.Size = UDim2.new(1, 0, 0, 14)
		value.TextXAlignment = Enum.TextXAlignment.Right
		value.ZIndex = 4
		local capt = label(col, "", 10, UI.font.body, UI.theme.dimmer)
		capt.Position = UDim2.fromOffset(0, 18)
		capt.Size = UDim2.new(1, 0, 0, 12)
		capt.TextXAlignment = Enum.TextXAlignment.Right
		capt.ZIndex = 4
		stats[i] = { value = value, caption = capt }
	end
	window.stats = stats

	----------------------------------------------------------------- pages
	local body = frame(content, UDim2.new(1, 0, 1, -38 - 52 - 50 - 22), UDim2.fromOffset(0, 90),
		UI.theme.window)
	body.ClipsDescendants = true
	body.ZIndex = 1
	window.body = body

	----------------------------------------------------------------- discord bar
	local discord = Instance.new("TextButton")
	discord.Size = UDim2.new(1, 0, 0, 50)
	discord.Position = UDim2.new(0, 0, 1, -72)
	discord.BackgroundColor3 = UI.theme.discord
	discord.BorderSizePixel = 0
	discord.Text = ""
	discord.AutoButtonColor = false
	discord.ZIndex = 2
	discord.Parent = content
	local discordGrad = Instance.new("UIGradient")
	discordGrad.Color = ColorSequence.new(UI.theme.discord, UI.theme.discordAlt)
	discordGrad.Parent = discord

	local dIcon = label(discord, "◉", 20, UI.font.heading, Color3.new(1, 1, 1))
	dIcon.Position = UDim2.fromOffset(15, 0)
	dIcon.Size = UDim2.fromOffset(24, 50)
	dIcon.TextXAlignment = Enum.TextXAlignment.Center
	dIcon.ZIndex = 3

	local dTitle = label(discord, "DISCORD BEITRETEN", 13, UI.font.heading, Color3.new(1, 1, 1))
	dTitle.Position = UDim2.fromOffset(52, 11)
	dTitle.Size = UDim2.fromOffset(300, 14)
	dTitle.ZIndex = 3

	local dSub = label(discord, "Codes, Updates & Support", 10, UI.font.body,
		Color3.new(1, 1, 1), 0.25)
	dSub.Position = UDim2.fromOffset(52, 28)
	dSub.Size = UDim2.fromOffset(300, 12)
	dSub.ZIndex = 3

	local dPill = frame(discord, UDim2.fromOffset(62, 26), UDim2.new(1, -77, 0, 12),
		Color3.new(1, 1, 1), 0.84)
	dPill.ZIndex = 3
	corner(dPill, 7)
	local dPillText = label(dPill, "JOIN →", 11, UI.font.heading, Color3.new(1, 1, 1))
	dPillText.Size = UDim2.fromScale(1, 1)
	dPillText.TextXAlignment = Enum.TextXAlignment.Center
	dPillText.ZIndex = 4

	discord.MouseEnter:Connect(function()
		tween(discord, EASE.soft, { BackgroundColor3 = UI.theme.accentAlt })
	end)
	discord.MouseLeave:Connect(function()
		tween(discord, EASE.soft, { BackgroundColor3 = UI.theme.discord })
	end)
	discord.MouseButton1Click:Connect(function()
		press(discord)
		local url = "https://" .. UI.DISCORD
		-- GuiService:OpenBrowserWindow really does open the system browser from a
		-- LocalScript - verified present in this client. It is not on every
		-- platform though, so the clipboard is still written either way: worst
		-- case the link is one paste away instead of lost.
		pcall(function() (setclipboard or toclipboard or set_clipboard)(url) end)
		local opened = pcall(function()
			game:GetService("GuiService"):OpenBrowserWindow(url)
		end)
		setText(dTitle, opened and "IM BROWSER GEOEFFNET" or "LINK KOPIERT")
		task.delay(2.5, function() setText(dTitle, "DISCORD BEITRETEN") end)
	end)

	----------------------------------------------------------------- footer
	local foot = frame(content, UDim2.new(1, 0, 0, 22), UDim2.new(0, 0, 1, -22), UI.theme.window)
	foot.ZIndex = 2
	local footText = label(foot, UI.DISCORD .. "  ·  Selux v" .. UI.VERSION, 10,
		UI.font.mono, UI.theme.fainter)
	footText.Size = UDim2.fromScale(1, 1)
	footText.TextXAlignment = Enum.TextXAlignment.Center
	footText.ZIndex = 3
	window.footText = footText

	----------------------------------------------------------------- state
	window.pages = {}
	window.current = nil
	window.chips = {}      -- toggle bookkeeping, keyed by a counter (see v2 note)
	window.chipSeq = 0
	window.collapsed = false

	-- Collapsing has to HIDE the lower furniture, not just shrink the window. The
	-- Discord bar and the footer are anchored to the bottom of the content frame,
	-- so shrinking alone slid both of them straight over the header and the strip
	-- - the collapsed panel was a blue block with the title behind it.
	headButton("–", -46, function()
		window.collapsed = not window.collapsed
		local target = window.collapsed and 90 or height
		if window.collapsed then
			body.Visible = false
			discord.Visible = false
			foot.Visible = false
		else
			-- back BEFORE the tween, so the panel does not open onto a blank area
			body.Visible = true
			discord.Visible = true
			foot.Visible = true
		end
		tween(root, EASE.slow, { Size = UDim2.fromOffset(width, target) })
	end)
	-- On a phone × HIDES rather than destroys. There is no RightShift there, so a
	-- destroyed panel is gone until the script is executed again - and × is
	-- exactly the button somebody presses to get their screen back. Hiding puts
	-- the pill up instead, which brings it straight back.
	headButton("×", -24, function()
		if UI.device == "mobile" then
			root.Visible = false
		else
			window:Destroy()
		end
	end)

	--------------------------------------------------------------- master toggle
	--
	-- SetMaster / SetStat are v3-only, so the nineteen scripts written against v1
	-- never call them. Left visible they render as a dead grey switch and three
	-- "-" columns next to a panel that is plainly running, which reads as broken
	-- UI. So both start HIDDEN and appear the first time a script actually uses
	-- them; the title slides left to take the space back.
	stripToggle.Visible = false
	stripTitle.Position = UDim2.fromOffset(15, 12)
	stripSub.Position = UDim2.fromOffset(15, 30)
	statHolder.Visible = false

	local masterState, masterCb = false, nil
	function window:SetMaster(on, caption, sub)
		if not stripToggle.Visible then
			stripToggle.Visible = true
			stripTitle.Position = UDim2.fromOffset(63, 12)
			stripSub.Position = UDim2.fromOffset(63, 30)
		end
		masterState = on and true or false
		tween(stripToggle, EASE.soft, {
			BackgroundColor3 = masterState and UI.theme.accent or UI.theme.band })
		tween(stripKnob, EASE.snap, {
			Position = UDim2.fromOffset(masterState and 18 or 3, 3),
			BackgroundColor3 = masterState and UI.theme.window or UI.theme.fainter })
		if caption then setText(stripTitle, caption) end
		if sub then setText(stripSub, sub) end
	end

	function window:OnMaster(fn) masterCb = fn end

	stripHit.MouseButton1Click:Connect(function()
		window:SetMaster(not masterState)
		if masterCb then task.spawn(masterCb, masterState) end
	end)

	--------------------------------------------------------------- public bits
	-- SetStatus keeps its v1 meaning - the live line of numbers - but it now
	-- writes the status strip's sub line, which is where the eye goes.
	function window:SetStatus(text)
		setText(stripSub, text)
		setText(headSub, options.subtitle)
	end

	function window:SetStat(index, value, caption)
		local s = stats[index]
		if not s then return end
		statHolder.Visible = true
		s.value.Text = tostring(value)
		if caption then setText(s.caption, caption) end
	end

	function window:SetNote(text) setText(stripTitle, text) end

	function window:Destroy()
		if pulseConn then pulseConn:Disconnect() pulseConn = nil end
		gui:Destroy()
	end

	-- Recount the toggles that are on, for the header's "N aktiv".
	function window:Refresh()
		local on, total = 0, 0
		for _, entry in pairs(self.chips) do
			total = total + 1
			if entry.on then on = on + 1 end
		end
		setFmt(activeCount, "%s aktiv", on)
		for _, page in ipairs(self.pages) do
			for _, card in ipairs(page.cards) do
				if card.countLabel then
					local c, t = 0, 0
					for _, e in ipairs(card.toggles) do
						t = t + 1
						if e.on then c = c + 1 end
					end
					if t > 0 then setFmt(card.countLabel, "%s / %s an", c, t)
					else setText(card.countLabel, "") end
				end
			end
		end
	end

	--------------------------------------------------------------- page switch
	local function show(page)
		if window.current == page then return end
		if window.current then window.current.holder.Visible = false end
		window.current = page
		page.holder.Visible = true
		setText(pageName, page.name)
		for _, p in ipairs(window.pages) do
			local active = p == page
			tween(p.railButton, EASE.quick, {
				BackgroundTransparency = active and 0.92 or 1 })
			p.tintIcon(active and UI.theme.accentAlt or UI.theme.dimmer)
			p.railMark.BackgroundTransparency = active and 0 or 1
		end
		-- Pages fade and lift; they never slide sideways. Sideways motion on a
		-- two-column grid looks like the layout is being rebuilt.
		local i = 0
		for _, card in ipairs(page.cards) do
			rise(card.root, i * 0.05)
			i = i + 1
		end
		page:Fill()
	end
	window.show = show

	--------------------------------------------------------------- Page
	function window:Page(name, iconGlyph)
		local page = { name = name, cards = {}, window = self }

		-- A SCROLLING page, not a fixed one. v3 first tried to make everything fit
		-- by shrinking the grid to whatever the full-width card left over - and
		-- with a 14-line read-out that left the two columns ~160px, so the cards
		-- were clipped mid-row and the read-out looked like it was lying on top of
		-- the options. Nothing may ever be squeezed or covered: the content takes
		-- the height it needs and the page scrolls if that is more than fits.
		page.holder = Instance.new("ScrollingFrame")
		page.holder.Size = UDim2.fromScale(1, 1)
		page.holder.BackgroundTransparency = 1
		page.holder.BorderSizePixel = 0
		page.holder.Visible = false
		page.holder.ZIndex = 1
		-- Wide enough to notice. At 3px and 40% transparent the bar was invisible
		-- against the panel, so a page with 788px of content in a 418px viewport
		-- read as "half the options are missing" rather than "scroll down".
		page.holder.ScrollBarThickness = 6
		page.holder.ScrollBarImageColor3 = UI.theme.accent
		page.holder.ScrollBarImageTransparency = 0.15
		page.holder.CanvasSize = UDim2.new()
		page.holder.AutomaticCanvasSize = Enum.AutomaticSize.Y
		page.holder.ScrollingDirection = Enum.ScrollingDirection.Y
		page.holder.ElasticBehavior = Enum.ElasticBehavior.Never
		page.holder.Parent = body

		-- The grid and the full-width strip are STACKED, never both anchored at
		-- y=12. v3 shipped them at the same offset for one build and the wide
		-- card (Card(name, 0), which every script uses for its read-out) drew
		-- straight on top of the two columns. A vertical list layout makes the
		-- order structural instead of arithmetic.
		local stack = frame(page.holder, UDim2.new(1, 0, 0, 0), nil, UI.theme.window, 1)
		stack.AutomaticSize = Enum.AutomaticSize.Y
		stack.ZIndex = 1
		pad(stack, 15, 18, 12, 12)
		listLayout(stack, 12)
		page.stack = stack

		-- two hand-built columns, never a UIGridLayout: a grid pins every cell to
		-- one size, which fights AutomaticSize and clipped every card in v1.
		-- Grid and columns size themselves to their content. Nothing is given a
		-- height it has to squeeze into, so a card can never be clipped and the
		-- full-width card below can never land on top of one.
		local grid = frame(stack, UDim2.new(1, 0, 0, 0), nil, UI.theme.window, 1)
		grid.AutomaticSize = Enum.AutomaticSize.Y
		grid.LayoutOrder = 1
		grid.ZIndex = 1
		page.grid = grid

		local colWidth = UDim2.new(0.5, -6, 0, 0)
		page.columns = {}
		for i = 1, 2 do
			local col = frame(grid, colWidth, UDim2.new(0.5 * (i - 1), (i - 1) * 6, 0, 0),
				UI.theme.window, 1)
			col.AutomaticSize = Enum.AutomaticSize.Y
			col.ZIndex = 1
			listLayout(col, 12)
			page.columns[i] = col
		end

		-- full-width strip UNDER the grid, for wide content (read-outs)
		page.wide = frame(stack, UDim2.new(1, 0, 0, 0), nil, UI.theme.window, 1)
		page.wide.AutomaticSize = Enum.AutomaticSize.Y
		page.wide.LayoutOrder = 2
		page.wide.ZIndex = 1
		listLayout(page.wide, 12)

		-- The mockup's lower block in each column is flex:1 - it eats whatever
		-- height is left, so the grid always reaches the bottom edge. Roblox has
		-- no flex, and without this the panel sits with a dead strip between the
		-- last card and the Discord bar, which reads as "the panel failed to
		-- load the rest". So: measure what the column actually used and stretch
		-- the last card by the difference.
		--
		-- It has to run in a task.defer. The cards were only just made visible,
		-- so AbsoluteSize is still last frame's and the sum comes out short.
		-- Only ever GROWS a card, never shrinks one. When the page is shorter than
		-- the viewport the shorter column's last card takes up the slack so the
		-- grid reaches the bottom edge like the mockup; when the page is longer,
		-- this does nothing at all and the page simply scrolls. The earlier
		-- version forced a height on the grid, which is what clipped the cards.
		--
		-- It has to run in a task.defer: the cards were only just made visible, so
		-- AbsoluteSize is still last frame's and every sum comes out short.
		function page:Fill()
			task.defer(function()
				if not self.holder.Parent then return end
				local viewport = body.AbsoluteSize.Y
				local content = self.stack.AbsoluteSize.Y
				local heights = {}
				for i, col in ipairs(self.columns) do
					local used, last = 0, nil
					for _, child in ipairs(col:GetChildren()) do
						if child:IsA("Frame") and child.Name ~= "__fill" then
							used = used + child.AbsoluteSize.Y + 12
							if not last or child.LayoutOrder >= last.LayoutOrder then
								last = child
							end
						end
					end
					heights[i] = { used = math.max(0, used - 12), last = last }
				end
				local tallest = math.max(heights[1].used, heights[2].used)
				-- if the whole page already overflows, no filling - just scroll
				local slackPage = viewport - content
				for _, h in ipairs(heights) do
					if h.last then
						local inner3 = h.last:FindFirstChildOfClass("Frame")
						local spacer = inner3 and inner3:FindFirstChild("__fill")
						local want = (tallest - h.used) + math.max(0, slackPage)
						if want > 2 and inner3 then
							if not spacer then
								spacer = frame(inner3, UDim2.new(1, 0, 0, 0), nil,
									UI.theme.card, 1)
								spacer.Name = "__fill"
								spacer.LayoutOrder = 99
								spacer.ZIndex = 2
							end
							spacer.Size = UDim2.new(1, 0, 0, want)
						elseif spacer then
							spacer:Destroy()
						end
					end
				end
			end)
		end

		-- rail button
		local btn = Instance.new("TextButton")
		btn.Size = UDim2.fromOffset(30, 30)
		btn.BackgroundColor3 = Color3.new(1, 1, 1)
		btn.BackgroundTransparency = 1
		btn.BorderSizePixel = 0
		btn.Text = ""
		btn.AutoButtonColor = false
		btn.LayoutOrder = #self.pages + 1
		btn.ZIndex = 3
		btn.Parent = railList
		corner(btn, 9)
		local icon, tintIcon = iconNode(btn, iconGlyph or UI.icon.grid, 16, UI.theme.dimmer)
		icon.Position = UDim2.new(0.5, -8, 0.5, -8)
		icon.ZIndex = 4
		page.tintIcon = tintIcon
		-- the active marker is an inset bar on the left, box-shadow:inset 2px 0 0
		local mark = frame(btn, UDim2.fromOffset(2, 18), UDim2.fromOffset(-8, 6), UI.theme.accent, 1)
		mark.ZIndex = 4
		corner(mark, 1)
		page.railButton, page.railIcon, page.railMark = btn, icon, mark

		btn.MouseEnter:Connect(function()
			if window.current ~= page then
				tween(btn, EASE.quick, { BackgroundTransparency = 0.94 })
			end
		end)
		btn.MouseLeave:Connect(function()
			if window.current ~= page then
				tween(btn, EASE.quick, { BackgroundTransparency = 1 })
			end
		end)
		btn.MouseButton1Click:Connect(function() show(page) end)

		------------------------------------------------------------ Card / block
		function page:Card(caption, column)
			local card = { toggles = {}, rows = {}, page = self }
			local parent = (column == 0) and self.wide or self.columns[column or 1]

			local root2 = frame(parent, UDim2.new(1, 0, 0, 0), nil, UI.theme.card)
			root2.AutomaticSize = Enum.AutomaticSize.Y
			root2.LayoutOrder = #parent:GetChildren()
			root2.ZIndex = 2
			corner(root2, 9)
			stroke(root2, UI.theme.band, 0)
			root2.ClipsDescendants = true
			card.root = root2

			local inner = frame(root2, UDim2.new(1, 0, 0, 0), nil, UI.theme.card, 1)
			inner.AutomaticSize = Enum.AutomaticSize.Y
			inner.ZIndex = 2
			listLayout(inner, 0)

			-- header band
			local band = frame(inner, UDim2.new(1, 0, 0, 30), nil, Color3.new(1, 1, 1), 0.965)
			band.LayoutOrder = 0
			band.ZIndex = 3
			local bandIcon, tintBand = iconNode(band, UI.icon.grid, 13, UI.theme.dim)
			bandIcon.Position = UDim2.fromOffset(11, 9)
			bandIcon.ZIndex = 4
			-- GothamBold, not the mono font. The mockup sets these in IBM Plex Mono
			-- and Roblox's stand-in for that is Enum.Font.Code, which at 10px
			-- uppercase comes out thin and smeared - "LOOP" and "PROGRESSION" were
			-- the two that made it obvious. Mono stays where it belongs: numbers.
			local bandText = label(band, string.upper(caption or ""), 11, UI.font.heading,
				UI.theme.muted)
			bandText.Position = UDim2.fromOffset(29, 0)
			bandText.Size = UDim2.new(1, -100, 0, 30)
			bandText.ZIndex = 4
			local countLabel = label(band, "", 10, UI.font.mono, UI.theme.dimmer)
			countLabel.Position = UDim2.new(1, -75, 0, 0)
			countLabel.Size = UDim2.fromOffset(64, 30)
			countLabel.TextXAlignment = Enum.TextXAlignment.Right
			countLabel.ZIndex = 4
			hairline(band, 0, UI.theme.band).Position = UDim2.new(0, 0, 1, -1)
			card.band, card.bandIcon, card.countLabel = band, bandIcon, countLabel

			local rows = frame(inner, UDim2.new(1, 0, 0, 0), nil, UI.theme.card, 1)
			rows.AutomaticSize = Enum.AutomaticSize.Y
			rows.LayoutOrder = 1
			rows.ZIndex = 3
			listLayout(rows, 0)
			card.rowHolder = rows

			-- Accent the band when the card is the primary one on the page.
			function card:Accent()
				band.BackgroundColor3 = UI.theme.accent
				band.BackgroundTransparency = 0.9
				tintBand(UI.theme.accentAlt)
				bandText.TextColor3 = UI.theme.accentSoft
				countLabel.TextColor3 = UI.theme.dim
				return self
			end

			function card:Icon(glyph)
				local colour = bandIcon:IsA("ImageLabel") and bandIcon.ImageColor3
					or bandIcon.TextColor3
				bandIcon:Destroy()
				bandIcon, tintBand = iconNode(band, glyph, 13, colour)
				bandIcon.Position = UDim2.fromOffset(11, 9)
				bandIcon.ZIndex = 4
				card.bandIcon = bandIcon
				return self
			end

			-- A row: title + hint on the left, control anchored to the TITLE LINE.
			-- With a two-line hint under it a vertically centred control drifts
			-- down into the hint and stops lining up with the thing it belongs to.
			local function row(caption2, hint, controlWidth)
				if #card.rows > 0 then
					local sep = frame(rows, UDim2.new(1, -22, 0, 1), nil, UI.theme.line)
					sep.LayoutOrder = #rows:GetChildren()
					sep.ZIndex = 3
					local sp = Instance.new("UIPadding")
					sp.PaddingLeft = UDim.new(0, 11)
					sp.Parent = sep
				end
				local r = frame(rows, UDim2.new(1, 0, 0, 0), nil, UI.theme.card, 1)
				r.AutomaticSize = Enum.AutomaticSize.Y
				r.LayoutOrder = #rows:GetChildren()
				r.ZIndex = 3

				local inner2 = frame(r, UDim2.new(1, -22, 0, 0), UDim2.fromOffset(11, 9),
					UI.theme.card, 1)
				inner2.AutomaticSize = Enum.AutomaticSize.Y
				inner2.ZIndex = 3
				local pb = Instance.new("UIPadding")
				pb.PaddingBottom = UDim.new(0, 9)
				pb.Parent = inner2

				local title = label(inner2, caption2 or "", 12, UI.font.body, UI.theme.textSoft)
				title.Size = UDim2.new(1, -(controlWidth or 40), 0, 14)
				title.ZIndex = 4

				local hintLabel
				if hint and hint ~= "" then
					-- The hint gets the FULL card width and wraps. Giving it the same
					-- -120 the caption reserves left it ~125px inside a two-column
					-- card and every hint longer than four words was truncated.
					hintLabel = label(inner2, hint, 10, UI.font.body, UI.theme.dimmer)
					hintLabel.Position = UDim2.fromOffset(0, 17)
					hintLabel.Size = UDim2.new(1, 0, 0, 0)
					hintLabel.AutomaticSize = Enum.AutomaticSize.Y
					hintLabel.TextWrapped = true
					hintLabel.TextYAlignment = Enum.TextYAlignment.Top
					hintLabel.ZIndex = 4
				end

				-- The hover/click surface is a TextButton behind the labels, not the
				-- row Frame: a Frame has no MouseEnter at all and assigning one
				-- throws rather than being ignored.
				local hover = Instance.new("TextButton")
				hover.Size = UDim2.fromScale(1, 1)
				hover.BackgroundColor3 = Color3.new(1, 1, 1)
				hover.BackgroundTransparency = 1
				hover.BorderSizePixel = 0
				hover.Text = ""
				hover.AutoButtonColor = false
				-- UNTER dem Inhalt, nicht darueber. Der ScreenGui laeuft mit
				-- ZIndexBehavior.Sibling, also entscheidet bei gleichem ZIndex die
				-- Reihenfolge - und hover wird nach r.inner erzeugt, lag also oben
				-- und fing jeden Klick ab. Toggles funktionierten trotzdem, weil die
				-- genau diese Flaeche benutzen; Dropdown, Stepper und Slider haben
				-- eigene Buttons und bekamen nie ein Ereignis. Ein transparenter
				-- Frame schluckt in Roblox keine Eingaben, also erreicht der Klick
				-- hover weiterhin ueberall dort, wo kein Bedienelement liegt.
				hover.ZIndex = 1
				hover.Parent = r
				hover.MouseEnter:Connect(function()
					tween(hover, EASE.quick, { BackgroundTransparency = 0.965 })
				end)
				hover.MouseLeave:Connect(function()
					tween(hover, EASE.quick, { BackgroundTransparency = 1 })
				end)

				local entry = { root = r, inner = inner2, title = title, hint = hintLabel,
				                hover = hover, caption = caption2 or "" }
				table.insert(card.rows, entry)
				return entry
			end
			card.row = row

			---------------------------------------------------------- Toggle
			function card:Toggle(caption2, initial, callback, hint, colour)
				local r = row(caption2, hint, 46)
				local state = initial and true or false

				local track = frame(r.inner, UDim2.fromOffset(34, 19),
					UDim2.new(1, -34, 0, -2), UI.theme.band)
				track.ZIndex = 5
				corner(track, 10)
				local knob = frame(track, UDim2.fromOffset(13, 13), UDim2.fromOffset(3, 3),
					UI.theme.fainter)
				knob.ZIndex = 6
				corner(knob, 7)

				-- ONE accent, always. Scripts pass UI.theme.warn for anything that
				-- spends and UI.theme.bad for anything destructive, and v1/v2 painted
				-- the switch in it - which put amber and rose toggles next to violet
				-- ones and made the panel look like three different tools. The
				-- mockup uses a single violet and that is the whole reason it reads
				-- calmly. The colour argument is still accepted (nothing to change
				-- in nineteen scripts) and is used for the row's meaning bar
				-- instead, where it informs without shouting.
				local onColour = UI.theme.accent
				if colour and colour ~= UI.theme.accent then
					local mark = frame(r.inner, UDim2.fromOffset(2, 12),
						UDim2.fromOffset(-11, 1), colour)
					mark.ZIndex = 5
					corner(mark, 1)
				end
				window.chipSeq = window.chipSeq + 1
				local key = window.chipSeq
				local entry = { on = state, caption = caption2 }
				window.chips[key] = entry
				table.insert(card.toggles, entry)

				local function paint(animate)
					local info = animate and EASE.snap or TweenInfo.new(0)
					tween(track, EASE.soft, {
						BackgroundColor3 = state and onColour or UI.theme.band })
					tween(knob, info, {
						Position = UDim2.fromOffset(state and 18 or 3, 3),
						BackgroundColor3 = state and UI.theme.window or UI.theme.fainter })
					entry.on = state
					window:Refresh()
				end
				paint(false)

				r.hover.MouseButton1Click:Connect(function()
					state = not state
					paint(true)
					if callback then task.spawn(callback, state) end
				end)

				return {
					set = function(a, b)
						local v = arg(a, b)
						state = v and true or false
						paint(true)
					end,
					get = function() return state end,
				}
			end

			---------------------------------------------------------- Slider
			function card:Slider(caption2, minValue, maxValue, initial, callback, hint)
				local r = row(caption2, hint, 60)
				local value = math.clamp(initial or minValue, minValue, maxValue)

				local readout = label(r.inner, tostring(value), 11, UI.font.mono,
					UI.theme.accentSoft)
				readout.Position = UDim2.new(1, -58, 0, 0)
				readout.Size = UDim2.fromOffset(58, 14)
				readout.TextXAlignment = Enum.TextXAlignment.Right
				readout.ZIndex = 5

				local trackY = r.hint and 40 or 22
				local track = frame(r.inner, UDim2.new(1, 0, 0, 3), UDim2.fromOffset(0, trackY),
					UI.theme.band)
				track.ZIndex = 5
				corner(track, 2)
				local fill = frame(track, UDim2.fromScale(0, 1), nil, UI.theme.accent)
				fill.ZIndex = 6
				corner(fill, 2)
				local knob = frame(track, UDim2.fromOffset(11, 11), UDim2.new(0, -5, 0, -4),
					UI.theme.textSoft)
				knob.ZIndex = 7
				corner(knob, 6)

				local hit = Instance.new("TextButton")
				hit.Size = UDim2.new(1, 0, 0, 18)
				hit.Position = UDim2.fromOffset(0, -7)
				hit.BackgroundTransparency = 1
				hit.Text = ""
				hit.ZIndex = 8
				hit.Parent = track

				local function apply(alpha, fire)
					alpha = math.clamp(alpha, 0, 1)
					value = math.floor(minValue + (maxValue - minValue) * alpha + 0.5)
					local a = (value - minValue) / math.max(1, maxValue - minValue)
					fill.Size = UDim2.fromScale(a, 1)
					knob.Position = UDim2.new(a, -5, 0, -4)
					readout.Text = tostring(value)
					if fire and callback then task.spawn(callback, value) end
				end
				apply((value - minValue) / math.max(1, maxValue - minValue), false)

				local dragging = false
				hit.MouseButton1Down:Connect(function() dragging = true end)
				UserInputService.InputEnded:Connect(function(input)
					if input.UserInputType == Enum.UserInputType.MouseButton1 then
						dragging = false
					end
				end)
				RunService.RenderStepped:Connect(function()
					if not dragging or not track.Parent then return end
					local mouse = UserInputService:GetMouseLocation()
					local a = (mouse.X - track.AbsolutePosition.X) / math.max(1, track.AbsoluteSize.X)
					apply(a, true)
				end)

				return { set = function(a, b)
					local v = arg(a, b)
					if v then apply((v - minValue) / math.max(1, maxValue - minValue), false) end
				end }
			end

			---------------------------------------------------------- Stepper
			function card:Stepper(caption2, getText, onStep, hint)
				local r = row(caption2, hint, 92)

				local function stepButton(text, x, dir)
					local b = Instance.new("TextButton")
					b.Size = UDim2.fromOffset(20, 20)
					b.Position = UDim2.new(1, x, 0, -3)
					b.BackgroundColor3 = UI.theme.input
					b.BorderSizePixel = 0
					setText(b, text)
					b.TextSize = 12
					b.Font = UI.font.heading
					b.TextColor3 = UI.theme.muted
					b.AutoButtonColor = false
					b.ZIndex = 5
					b.Parent = r.inner
					corner(b, 6)
					stroke(b, UI.theme.band, 0)
					return b
				end

				-- The value gets its own centred chip between - and +, never glued
				-- to the label, or a long value truncates. The chip WIDTH follows
				-- the text: at a fixed 50px "smart ladder" rendered as "art ladde"
				-- and "auto 1" lost its tail. It grows, and the two buttons and the
				-- caption move out of its way - nothing else changes.
				local chip = frame(r.inner, UDim2.fromOffset(50, 20), UDim2.new(1, -72, 0, -3),
					UI.theme.input)
				chip.ZIndex = 5
				corner(chip, 6)
				stroke(chip, UI.theme.band, 0)
				local chipText = label(chip, "", 11, UI.font.mono, UI.theme.accentSoft)
				chipText.Size = UDim2.fromScale(1, 1)
				chipText.TextXAlignment = Enum.TextXAlignment.Center
				chipText.ZIndex = 6

				local minus = stepButton("−", -92, -1)
				local plus = stepButton("+", -20, 1)

				local CHIP_MIN, CHIP_MAX = 50, 190
				local function refresh()
					local ok, text = pcall(getText)
					text = ok and tostring(text) or "-"
					setText(chipText, text)
					-- TextService:GetTextSize, never TextBounds: a label that has not
					-- rendered yet reports zero on the first frame, and the chip
					-- would collapse to its minimum on every rebuild.
					local measured = TextService:GetTextSize(text, 11, UI.font.mono,
						Vector2.new(1000, 100)).X
					local width = math.clamp(math.ceil(measured) + 18, CHIP_MIN, CHIP_MAX)
					chip.Size = UDim2.fromOffset(width, 20)
					chip.Position = UDim2.new(1, -(width + 22), 0, -3)
					minus.Position = UDim2.new(1, -(width + 44), 0, -3)
					-- the caption gives up exactly what the controls now take
					r.title.Size = UDim2.new(1, -(width + 52), 0, 14)
				end
				-- after the definition, never before it: a local is invisible above
				-- the line that declares it, so calling refresh() earlier resolves
				-- to a nil global and throws.
				refresh()

				local function bind(button, dir)
					button.MouseButton1Click:Connect(function()
						press(button, UI.theme.accent)
						if onStep then pcall(onStep, dir) end
						refresh()
					end)
					button.MouseEnter:Connect(function()
						tween(button, EASE.quick, { BackgroundColor3 = UI.theme.cardHover })
					end)
					button.MouseLeave:Connect(function()
						tween(button, EASE.quick, { BackgroundColor3 = UI.theme.input })
					end)
				end
				bind(minus, -1)
				bind(plus, 1)

				return refresh
			end

			---------------------------------------------------------- Dropdown
			function card:Dropdown(caption2, choices, initial, callback)
				local r = row(caption2, nil, 100)
				local value = initial or (choices and choices[1]) or ""

				local box = Instance.new("TextButton")
				box.Size = UDim2.fromOffset(96, 22)
				box.Position = UDim2.new(1, -96, 0, -4)
				box.BackgroundColor3 = UI.theme.input
				box.BorderSizePixel = 0
				box.Text = ""
				box.AutoButtonColor = false
				box.ZIndex = 5
				box.Parent = r.inner
				corner(box, 7)
				stroke(box, UI.theme.band, 0)

				local boxText = label(box, tostring(value), 11, UI.font.mono, UI.theme.accentSoft)
				boxText.Position = UDim2.fromOffset(9, 0)
				boxText.Size = UDim2.new(1, -24, 1, 0)
				boxText.ZIndex = 6
				-- ▼/▲, never ▾/▴: the small forms are tofu in Gotham.
				local arrow = label(box, "▼", 8, UI.font.body, UI.theme.dimmer)
				arrow.Position = UDim2.new(1, -18, 0, 0)
				arrow.Size = UDim2.fromOffset(14, 22)
				arrow.ZIndex = 6

				-- The menu hangs off the WINDOW, not off the row. Every card sets
				-- ClipsDescendants so its rounded corners hold, which cut the open
				-- menu off after a few pixels - it looked like the dropdown simply
				-- did nothing. Parented to the root it can overhang the card, and
				-- its position is taken from the box on every open because the page
				-- scrolls underneath it.
				local menu = frame(root, UDim2.fromOffset(96, 0), UDim2.fromOffset(0, 0),
					UI.theme.input)
				menu.Visible = false
				menu.ZIndex = 200
				menu.AutomaticSize = Enum.AutomaticSize.Y
				corner(menu, 7)
				stroke(menu, UI.theme.band, 0)
				listLayout(menu, 0)

				for index, choice in ipairs(choices or {}) do
					local item = Instance.new("TextButton")
					item.Size = UDim2.new(1, 0, 0, 22)
					item.BackgroundColor3 = UI.theme.input
					item.BackgroundTransparency = 1
					item.BorderSizePixel = 0
					setText(item, "  " .. tostring(choice))
					item.TextSize = 11
					item.Font = UI.font.mono
					item.TextColor3 = UI.theme.muted
					item.TextXAlignment = Enum.TextXAlignment.Left
					item.AutoButtonColor = false
					item.LayoutOrder = index
					item.ZIndex = 21
					item.Parent = menu
					item.MouseEnter:Connect(function()
						tween(item, EASE.quick, { BackgroundTransparency = 0.9,
							TextColor3 = UI.theme.accentSoft })
					end)
					item.MouseLeave:Connect(function()
						tween(item, EASE.quick, { BackgroundTransparency = 1,
							TextColor3 = UI.theme.muted })
					end)
					item.MouseButton1Click:Connect(function()
						value = choice
						setText(boxText, tostring(choice))
						menu.Visible = false
						if callback then task.spawn(callback, choice) end
					end)
				end

				box.MouseButton1Click:Connect(function()
					if not menu.Visible then
						local at = box.AbsolutePosition - root.AbsolutePosition
						menu.Position = UDim2.fromOffset(at.X, at.Y + box.AbsoluteSize.Y + 3)
						menu.Size = UDim2.fromOffset(box.AbsoluteSize.X, 0)
					end
					menu.Visible = not menu.Visible
					arrow.Text = menu.Visible and "▲" or "▼"
				end)
				-- a menu left open while the page scrolls would float in mid-air
				page.holder:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
					menu.Visible = false
					arrow.Text = "▼"
				end)

				return { set = function(a, b)
					local v = arg(a, b)
					if v ~= nil then value = v setText(boxText, tostring(v)) end
				end }
			end

			---------------------------------------------------------- Button
			function card:Button(caption2, callback, colour)
				local r = row(nil, nil, 0)
				r.inner.Size = UDim2.new(1, -22, 0, 32)
				r.inner.AutomaticSize = Enum.AutomaticSize.None
				r.title:Destroy()

				local b = Instance.new("TextButton")
				b.Size = UDim2.new(1, 0, 0, 32)
				b.BackgroundColor3 = colour or UI.theme.accent
				b.BorderSizePixel = 0
				setText(b, string.upper(caption2 or ""))
				b.TextSize = 11
				b.Font = UI.font.heading
				b.TextColor3 = (colour and colour ~= UI.theme.accent)
					and Color3.new(1, 1, 1) or UI.theme.window
				b.AutoButtonColor = false
				b.ZIndex = 5
				b.Parent = r.inner
				corner(b, 8)

				b.MouseEnter:Connect(function()
					tween(b, EASE.soft, { Position = UDim2.fromOffset(0, -1) })
				end)
				b.MouseLeave:Connect(function()
					tween(b, EASE.soft, { Position = UDim2.fromOffset(0, 0) })
				end)
				b.MouseButton1Click:Connect(function()
					press(b)
					if callback then task.spawn(callback) end
				end)
				return b
			end

			---------------------------------------------------------- Label
			function card:Label(text)
				local r = row(nil, nil, 0)
				r.title:Destroy()
				-- Gotham, nicht Code: die Mono-Schrift franst bei 10px sichtbar aus.
				-- Mono bleibt Zahlen vorbehalten (Readout, Stepper, Statuszeile).
				local l = label(r.inner, text or "", 11, UI.font.body, UI.theme.dimmer)
				l.Size = UDim2.new(1, 0, 0, 0)
				l.AutomaticSize = Enum.AutomaticSize.Y
				l.TextWrapped = true
				l.TextYAlignment = Enum.TextYAlignment.Top
				l.ZIndex = 5
				return {
					set = function(a, b) setText(l, arg(a, b)) end,
					label = l,
				}
			end

			---------------------------------------------------------- Readout
			function card:Readout(lines, colourFor)
				local height2 = (lines or 10) * 13 + 16
				local r = row(nil, nil, 0)
				r.title:Destroy()
				r.inner.Size = UDim2.new(1, -22, 0, height2)
				r.inner.AutomaticSize = Enum.AutomaticSize.None

				local box = frame(r.inner, UDim2.new(1, 0, 0, height2), nil, UI.theme.void)
				box.ZIndex = 5
				corner(box, 7)
				stroke(box, UI.theme.band, 0)
				local holder = frame(box, UDim2.new(1, -20, 1, -14), UDim2.fromOffset(10, 7),
					UI.theme.void, 1)
				holder.ZIndex = 6
				listLayout(holder, 1)

				local rowLabels = {}
				for i = 1, (lines or 10) do
					local l = label(holder, "", 11, UI.font.mono, UI.theme.muted)
					l.Size = UDim2.new(1, 0, 0, 12)
					l.LayoutOrder = i
					l.ZIndex = 7
					rowLabels[i] = l
				end

				return {
					-- Called as out:set(lines) by every script, so the table arrives
					-- as the first argument and the list as the second. Written as
					-- set(list) the whole read-out silently stayed blank - which is
					-- exactly what v3 shipped with for one build. Accept both forms.
					set = function(a, b)
						local list = arg(a, b)
						for i, l in ipairs(rowLabels) do
							local text = list and list[i] or ""
							setText(l, text)
							-- ALL-CAPS lines render as accent headings, same as v1/v2.
							local isHead = text ~= "" and text == string.upper(text)
								and not text:match("^%s")
							local colour = colourFor and colourFor(text) or nil
							l.TextColor3 = colour or (isHead and UI.theme.accentSoft
								or UI.theme.muted)
						end
					end,
					labels = rowLabels,
				}
			end

			table.insert(self.cards, card)
			return card
		end

		table.insert(self.pages, page)
		if not window.current then show(page) end
		return page
	end

	--------------------------------------------------------------- HOME
	--
	-- Always the first entry in the rail, always the page you land on. Everything
	-- ships through a public GitHub repo anyway, so the commit log IS the
	-- changelog - there is no second list to maintain and no way for it to drift
	-- out of date. Commits here are written "<script>: what changed", which is
	-- exactly "which game was updated" plus "what happened".
	function window:Home(options2)
		options2 = options2 or {}
		local page = self:Page(options2.name or "Home", UI.icon.home)

		-- Move it to the front of the rail and make it the landing page. Page()
		-- appends, so without this Home would sit wherever it was declared.
		table.remove(self.pages, #self.pages)
		table.insert(self.pages, 1, page)
		for i, p in ipairs(self.pages) do p.railButton.LayoutOrder = i end
		show(page)

		-- Six, not eight. Each entry is ~46px and the body is 420px tall, so
		-- eight ran straight under the Discord bar and the last two were
		-- unreachable. Six fills the page and stops at the edge.
		-- Two columns like the mockup: the changelog as a timeline on the left,
		-- what the panel is doing right now on the right. Not full width - a
		-- single wide list of commits is all a HOME page would be, and the
		-- interesting half is "is my farm actually running".
		local card = page:Card("CHANGELOG", 1):Accent():Icon(UI.icon.clock)
		card:Label("laedt ...")
		local body2 = card.rowHolder

		-- Deliberately does NOT repeat wins / rate / rebirths: those are already in
		-- the status strip two centimetres above, and printing them twice on the
		-- same screen is just noise. What is not up there is which page you are
		-- on, how long this session has been running and where the script came
		-- from - so that is what goes here.
		local live = page:Card("LAEUFT GERADE", 2):Icon(UI.icon.loop)
		local liveTitle = live:Label("-")
		local liveSub = live:Label("")
		local liveMeta = live:Label("")
		page.live = { title = liveTitle, sub = liveSub, meta = liveMeta }

		local started = os.clock()
		task.spawn(function()
			while page.holder.Parent do
				liveTitle.set(window.stripTitle.Text)
				liveSub.set(window.stripSub.Text)
				local mins = math.floor((os.clock() - started) / 60)
				liveMeta.set(UI.tf("Sitzung %d min  ·  %d Seiten  ·  Selux v%s",
					mins, #window.pages, UI.VERSION))
				task.wait(5)
			end
		end)

		-- Report card. Sits on Home, under the live panel, so a user who thinks
		-- something is broken finds it without being told where to look.
		local report = page:Card("PROBLEM MELDEN", 2):Icon(UI.icon.shield)
		local reportHint = report:Label("Script kaputt oder Spiel geupdatet? Ein Klick reicht - wenn du willst, schreib kurz dazu was nicht geht.")

		-- Optional free text. Deliberately an inline field and not a popup: a
		-- modal would make the common case (just press it) two clicks, and a
		-- report with nothing typed is still worth having.
		local MAX_MESSAGE = 300
		local msgRow = report.row(nil, nil, 0)
		msgRow.title:Destroy()
		msgRow.inner.Size = UDim2.new(1, -22, 0, 58)
		msgRow.inner.AutomaticSize = Enum.AutomaticSize.None
		local msgBox = frame(msgRow.inner, UDim2.new(1, 0, 0, 58), nil, UI.theme.input)
		msgBox.ZIndex = 5
		corner(msgBox, 7)
		stroke(msgBox, UI.theme.band, 0)
		pad(msgBox, 9, 9, 7, 7)
		local msgInput = Instance.new("TextBox")
		msgInput.BackgroundTransparency = 1
		msgInput.Size = UDim2.fromScale(1, 1)
		msgInput.Text = ""
		setPlaceholder(msgInput, "Was genau geht nicht? (optional)")
		msgInput.TextSize = 11
		msgInput.Font = UI.font.body
		msgInput.TextColor3 = UI.theme.textSoft
		msgInput.PlaceholderColor3 = UI.theme.faint
		msgInput.TextXAlignment = Enum.TextXAlignment.Left
		msgInput.TextYAlignment = Enum.TextYAlignment.Top
		msgInput.TextWrapped = true
		msgInput.MultiLine = true
		msgInput.ClearTextOnFocus = false
		msgInput.ZIndex = 6
		msgInput.Parent = msgBox
		local counter = label(msgRow.inner, "", 9, UI.font.mono, UI.theme.fainter)
		counter.Position = UDim2.new(1, -60, 0, 60)
		counter.Size = UDim2.fromOffset(60, 12)
		counter.TextXAlignment = Enum.TextXAlignment.Right
		counter.ZIndex = 6
		-- Cut at the ceiling as it is typed. The Worker caps it too, but silently
		-- losing the end of what somebody wrote is worse than stopping them.
		msgInput:GetPropertyChangedSignal("Text"):Connect(function()
			if #msgInput.Text > MAX_MESSAGE then
				msgInput.Text = string.sub(msgInput.Text, 1, MAX_MESSAGE)
			end
			counter.Text = #msgInput.Text .. " / " .. MAX_MESSAGE
		end)

		-- THREE GATES, because a bright button that costs nothing gets pressed out
		-- of curiosity. Measured on the live relay: the reports arriving carried
		-- notes like "Bereit" and "Gestoppt" and statuses like "0 wins lvl 0 reb 0"
		-- - panels that had just been loaded. Nobody had a problem; they had a
		-- button. A report from a panel that has not run yet says nothing and
		-- buries the real ones.
		local READY_AFTER = 60          -- seconds the script must have run
		local openedAt = os.clock()
		local reportBtn
		local sent, armed = false, false

		-- Gate 1: is there anything to report yet? Either the script has been
		-- running a while, or it has already parked a real complaint in the
		-- status strip - STATE.blocked and the error notes both land there.
		local function haveSomethingToSay()
			if os.clock() - openedAt >= READY_AFTER then return true end
			if msgInput.Text ~= "" then return true end
			local note = (window.stripTitle and window.stripTitle.Text or "") .. " "
				.. (window.stripSub and window.stripSub.Text or "")
			note = string.lower(note)
			for _, word in ipairs({ "fail", "error", "refus", "blocked", "stuck",
				"stall", "nicht", "kein", "fehler" }) do
				if string.find(note, word, 1, true) then return true end
			end
			return false
		end

		reportBtn = report:Button("MELDEN", function()
			if sent then return end

			if not haveSomethingToSay() then
				local left = math.ceil(READY_AFTER - (os.clock() - openedAt))
				reportHint.set(UI.tf("Das Panel laeuft erst %ds. Lass es kurz laufen (noch %ds) - oder schreib oben rein, was nicht geht, dann geht es sofort.", READY_AFTER - left, left))
				return
			end

			-- Gate 2: a second press confirms. Anyone who typed something has
			-- already shown intent, so they skip it.
			if not armed and msgInput.Text == "" then
				armed = true
				setText(reportBtn, "WIRKLICH MELDEN?")
				reportBtn.BackgroundColor3 = UI.theme.bad
				reportHint.set("Nochmal druecken zum Senden. Besser: schreib kurz rein, was nicht geht - dann kann ich es auch beheben.")
				task.delay(8, function()
					if not sent and armed then
						armed = false
						setText(reportBtn, "MELDEN")
						reportBtn.BackgroundColor3 = UI.theme.warn
					end
				end)
				return
			end

			local r = UI.buildReport(window)
			r.message = msgInput.Text
			-- The clipboard fallback wants it on one line; the relay gets the
			-- message as its own field and formats it itself.
			if r.message ~= "" then
				r.text = r.text .. "  |  Text: " .. r.message
			end
			local ok, how = UI.sendReport(r)
			if not ok then
				reportHint.set("Konnte nicht senden. Bitte im Discord im Support-Forum melden.")
				return
			end
			-- Locked afterwards: the same person pressing twenty times tells us
			-- nothing more than pressing once, and it is the whole spam surface.
			sent = true
			if how == "limit" then
				-- Not delivered. Say so, and give the user the way round it.
				setText(reportBtn, "LIMIT ERREICHT")
				reportBtn.BackgroundColor3 = UI.theme.warn
				pcall(function()
					(setclipboard or toclipboard or set_clipboard)(r.text)
				end)
				reportHint.set("Von dieser Verbindung kamen zuletzt zu viele Meldungen, diese wurde NICHT zugestellt. Sie liegt in der Zwischenablage - fueg sie im Discord unter #support ein, oder probier es gleich nochmal.")
			elseif how == "doppelt" then
				setFmt(reportBtn, "SCHON GEMELDET  #%s", r.id)
				reportBtn.BackgroundColor3 = UI.theme.warn
				reportHint.set("Dieses Problem wurde fuer dieses Spiel gerade schon gemeldet - es ist angekommen, aber nicht doppelt.")
			elseif how == "clipboard" then
				setFmt(reportBtn, "KOPIERT  #%s", r.id)
				reportBtn.BackgroundColor3 = UI.theme.good
				reportHint.set(UI.tf("In die Zwischenablage kopiert - bitte im Discord unter #support einfuegen. Nummer #%s", r.id))
			else
				setFmt(reportBtn, "GEMELDET - DANKE  #%s", r.id)
				reportBtn.BackgroundColor3 = UI.theme.good
				reportHint.set(UI.tf("Angekommen. Nummer #%s - die kannst du im Support-Forum nennen.", r.id))
			end
		end, UI.theme.warn)
		report:Label("Mitgeschickt werden Spiel, Script-Version, der letzte Status und die aktiven Optionen. Kein Roblox-Name, keine UserId.")

		local function paint(list, err)
			for _, child in ipairs(body2:GetChildren()) do
				if child:IsA("Frame") then child:Destroy() end
			end
			if not list then
				card:Label(err or "keine Verbindung zu GitHub")
				return
			end
			-- A real timeline: the dots live in their own 18px gutter with a hairline
			-- running through them, and the text starts after it. Dropped at a
			-- negative offset next to the title - which is what this did first -
			-- they read as specks stuck onto the text rather than as a rail.
			local GUTTER = 18
			for index, entry in ipairs(list) do
				local r = card.row(entry.game, entry.summary, 54)
				r.title.TextColor3 = UI.theme.text
				r.title.Font = UI.font.heading
				r.title.Position = UDim2.fromOffset(GUTTER, 0)
				r.title.Size = UDim2.new(1, -GUTTER - 54, 0, 14)
				if r.hint then
					r.hint.Position = UDim2.fromOffset(GUTTER, 17)
					r.hint.Size = UDim2.new(1, -GUTTER, 0, 0)
				end

				local newest = index == 1
				-- the line runs the full row height, behind the dot
				if index < #list then
					local link = frame(r.inner, UDim2.new(0, 1, 1, -6),
						UDim2.fromOffset(4, 12), UI.theme.band)
					link.ZIndex = 4
				end
				local dot = frame(r.inner, UDim2.fromOffset(newest and 9 or 7,
					newest and 9 or 7), UDim2.fromOffset(newest and 0 or 1, newest and 3 or 4),
					newest and UI.theme.accent or UI.theme.fainter)
				dot.ZIndex = 6
				corner(dot, 5)
				if newest then registerPulse(dot, 2.2, 0.55, 0) end

				local age = label(r.inner, entry.when, 10, UI.font.mono, UI.theme.faint)
				age.Position = UDim2.new(1, -50, 0, 0)
				age.Size = UDim2.fromOffset(50, 14)
				age.TextXAlignment = Enum.TextXAlignment.Right
				age.ZIndex = 5
			end
			page:Fill()
		end

		-- Never on the main thread: an executor with no working http, or GitHub
		-- rate-limiting the IP, must leave the panel usable.
		local function load()
			task.spawn(function()
				local ok, list, err = pcall(UI.commits, options2.limit or 6)
				paint(ok and list or nil, ok and err or "GitHub nicht erreichbar")
			end)
		end
		load()
		page.reload = load

		return page
	end

	--------------------------------------------------------------- search
	search:GetPropertyChangedSignal("Text"):Connect(function()
		local query = string.lower(search.Text)
		for _, page in ipairs(window.pages) do
			local pageHits = 0
			for _, card in ipairs(page.cards) do
				local cardHits = 0
				for _, r in ipairs(card.rows) do
					local hit = query == "" or string.find(string.lower(r.caption), query, 1, true)
					r.root.Visible = hit and true or false
					if hit then cardHits = cardHits + 1 end
				end
				card.root.Visible = (query == "") or cardHits > 0
				pageHits = pageHits + cardHits
			end
			-- dim the rail entry of a page with no hits at all
			page.railIcon.ImageTransparency = page.railIcon:IsA("ImageLabel")
				and ((query ~= "" and pageHits == 0) and 0.7 or 0) or nil
			if page.railIcon:IsA("TextLabel") then
				page.railIcon.TextTransparency = (query ~= "" and pageHits == 0) and 0.7 or 0
			end
		end
	end)

	--------------------------------------------------------------- hotkey
	local hotkey = options.hotkey or Enum.KeyCode.RightShift
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then return end
		if input.KeyCode == hotkey then
			root.Visible = not root.Visible
		end
	end)

	--------------------------------------------------------------- the question
	-- Once per executor: the card goes up, the panel waits behind it, and the
	-- panel is revealed at the chosen scale the moment the question is answered.
	-- The wait is polled rather than wired to a callback because askDevice builds
	-- ONE card for however many panels are open, and every one of them has to be
	-- released by that single answer.
	--
	-- The 45s ceiling is the safety net: a card that is lost (a game that wipes
	-- the PlayerGui, an executor that refuses the ScreenGui) must not leave a
	-- running panel invisible forever.
	if pendingDevice then
		task.defer(function()
			pcall(UI.askDevice)
			local waited = 0
			while not UI.deviceAsked and waited < 45 do
				task.wait(0.2)
				waited = waited + 0.2
			end
			window.applyScale()
			root.Visible = true
		end)
	end

	return window
end

--------------------------------------------------------------------------------
-- the HOME page
--------------------------------------------------------------------------------
--
-- Everything ships through a public GitHub repo anyway, so the commit log IS the
-- changelog - there is no second list to maintain and no way for it to go stale.
-- Every commit in this project is written as "<script>: what changed", which is
-- exactly "which game was updated" plus "what happened", so the parse is a split
-- on the first colon.
--
--   win:Home()                       -- builds the page, fetches in the background
--   UI.commits(limit) -> list        -- if a script wants the raw data
--
-- The fetch is wrapped in pcall and runs in a task.spawn: an executor without a
-- working http_request, or GitHub rate-limiting the IP, must degrade to "keine
-- Verbindung" rather than take the panel down with it.

local function httpGet(url)
	local request = (syn and syn.request) or (http and http.request) or http_request or request
	if request then
		local ok, response = pcall(request, {
			Url = url, Method = "GET",
			Headers = { ["User-Agent"] = "Selux", ["Accept"] = "application/vnd.github+json" },
		})
		if ok and response and response.Body then return response.Body end
	end
	local ok, body = pcall(function() return game:HttpGet(url) end)
	if ok then return body end
	return nil
end

local function ago(iso)
	-- "2026-08-20T03:32:46Z" -> "2 Std". No os.difftime on a parsed string in
	-- Luau, so the parts are pulled out with a pattern and fed to os.time.
	local y, mo, d, h, mi, s = string.match(iso or "",
		"(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
	if not y then return "" end
	local when = os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d),
		hour = tonumber(h), min = tonumber(mi), sec = tonumber(s) })
	-- os.time treats the table as local time; the stamp is UTC, so correct by the
	-- machine's own offset instead of assuming a timezone.
	local offset = os.time() - os.time(os.date("!*t", os.time()))
	local delta = os.time() - (when + offset)
	if delta < 90 then return UI.t("gerade eben") end
	if delta < 5400 then return UI.tf("%d Min", math.floor(delta / 60)) end
	if delta < 172800 then return UI.tf("%d Std", math.floor(delta / 3600)) end
	return UI.tf("%d Tage", math.floor(delta / 86400))
end

-- A one-click "this is broken" report ------------------------------------------
--
-- The user types NOTHING. Everything worth knowing is already on screen: which
-- game, which script version, and - the valuable part - the panel's own last
-- note, which is where these scripts write the reason something failed. A report
-- built from that is actionable without a single follow-up question.
--
-- What is deliberately NOT sent: the Roblox name and user id. Those are somebody
-- else's account, they are not needed to fix a script, and collecting them from
-- strangers is not something a bug button should do quietly.

local function executorName()
	local ok, name = pcall(function()
		return (identifyexecutor or getexecutorname or function() return nil end)()
	end)
	return (ok and name) or "unbekannt"
end

function UI.buildReport(window, note)
	local placeId = tostring(game.PlaceId)
	local gameName = "?"
	pcall(function()
		gameName = (_G.__SEL and _G.__SEL.game and _G.__SEL.game.name) or game.Name or "?"
	end)
	local alias = "?"
	pcall(function() alias = (_G.__SEL and _G.__SEL.game and _G.__SEL.game.alias) or "?" end)

	local active = {}
	if window and window.chips then
		for _, entry in pairs(window.chips) do
			if entry.on and entry.caption then table.insert(active, entry.caption) end
		end
	end
	table.sort(active)

	local report = {
		place = placeId,
		game = gameName,
		script = alias,
		ui = UI.VERSION,
		executor = executorName(),
		-- the panel's own words: status line, last note, and whatever the script
		-- parked in STATE.blocked
		status = window and window.stripSub and window.stripSub.Text or "",
		note = note or (window and window.stripTitle and window.stripTitle.Text) or "",
		active = table.concat(active, ", "),
		at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
	}
	-- short id so the user has something to quote in the support forum
	local seed = 0
	for _, ch in ipairs({ string.byte(placeId .. report.at, 1, -1) }) do
		seed = (seed * 31 + ch) % 0xFFFFFF
	end
	report.id = string.format("%04x", seed % 0xFFFF)

	report.text = table.concat({
		"**Selux report #" .. report.id .. "**",
		"Spiel: " .. report.game .. "  (place " .. report.place .. ")",
		"Script: " .. report.script .. "   UI v" .. report.ui,
		"Status: " .. (report.status ~= "" and report.status or "-"),
		"Notiz: " .. (report.note ~= "" and report.note or "-"),
		"Aktiv: " .. (report.active ~= "" and report.active or "-"),
		"Executor: " .. report.executor .. "   " .. report.at,
	}, "\n")
	return report
end

-- Returns ok, wie ("relay" | "clipboard" | "keiner")
function UI.sendReport(report)
	if UI.REPORT_URL ~= "" then
		local request = (syn and syn.request) or (http and http.request) or http_request or request
		if request then
			local ok, response = pcall(request, {
				Url = UI.REPORT_URL,
				Method = "POST",
				Headers = { ["Content-Type"] = "application/json" },
				Body = HttpService:JSONEncode(report),
			})
			if ok and response and (response.StatusCode or 0) < 400 then
				-- READ THE BODY, NOT JUST THE STATUS. The relay answers 200 for
				-- three different outcomes on purpose - delivered, dropped by the
				-- rate limit, dropped as a duplicate - because the panel has
				-- already thanked the user and a spammer should not learn which
				-- gate they hit. But telling the user "Angekommen" when it was
				-- silently discarded is a lie, and it cost a whole debugging
				-- round: the panel said it arrived, Discord was empty, and the
				-- only trace was a counter sitting at its cap in KV.
				local body = tostring(response.Body or "")
				if string.find(body, "limit", 1, true) then
					return true, "limit"
				elseif string.find(body, "dup", 1, true) then
					return true, "doppelt"
				end
				return true, "relay"
			end
		end
	end
	-- No relay, or it refused: the clipboard still gets the report to us.
	local ok = pcall(function()
		(setclipboard or toclipboard or set_clipboard)(report.text)
	end)
	return ok, ok and "clipboard" or "keiner"
end

function UI.commits(limit)
	local body = httpGet("https://api.github.com/repos/" .. UI.REPO ..
		"/commits?per_page=" .. tostring(limit or 8))
	if not body then return nil, "keine Verbindung" end
	local ok, data = pcall(function() return HttpService:JSONDecode(body) end)
	if not ok or type(data) ~= "table" then return nil, "unlesbare Antwort" end
	local out = {}
	for _, entry in ipairs(data) do
		local message = entry.commit and entry.commit.message or ""
		message = string.match(message, "^[^\n]*") or message
		local game_, summary = string.match(message, "^([%w%-_%.]+):%s*(.+)$")
		table.insert(out, {
			game = game_ or "hub",
			summary = summary or message,
			when = ago(entry.commit and entry.commit.author and entry.commit.author.date),
			sha = string.sub(entry.sha or "", 1, 7),
		})
	end
	return out
end

return UI
