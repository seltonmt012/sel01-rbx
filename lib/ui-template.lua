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
	l.Text = text or ""
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
	local searchWrap = frame(head, UDim2.fromOffset(172, 24), UDim2.new(1, -322, 0, 7),
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
	search.PlaceholderText = "Suche"
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
	activeCount.Position = UDim2.new(1, -122, 0, 0)
	activeCount.Size = UDim2.fromOffset(60, 38)
	activeCount.TextXAlignment = Enum.TextXAlignment.Right
	activeCount.ZIndex = 3
	window.activeCount = activeCount

	local function headButton(text, offset, onClick)
		local b = Instance.new("TextButton")
		b.Size = UDim2.fromOffset(20, 20)
		b.Position = UDim2.new(1, offset, 0, 9)
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
		dTitle.Text = opened and "IM BROWSER GEOEFFNET" or "LINK KOPIERT"
		task.delay(2.5, function() dTitle.Text = "DISCORD BEITRETEN" end)
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
	headButton("×", -24, function() window:Destroy() end)

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
		if caption then stripTitle.Text = caption end
		if sub then stripSub.Text = sub end
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
		stripSub.Text = text or ""
		headSub.Text = options.subtitle or ""
	end

	function window:SetStat(index, value, caption)
		local s = stats[index]
		if not s then return end
		statHolder.Visible = true
		s.value.Text = tostring(value)
		if caption then s.caption.Text = caption end
	end

	function window:SetNote(text) stripTitle.Text = text or "" end

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
		activeCount.Text = on .. " aktiv"
		for _, page in ipairs(self.pages) do
			for _, card in ipairs(page.cards) do
				if card.countLabel then
					local c, t = 0, 0
					for _, e in ipairs(card.toggles) do
						t = t + 1
						if e.on then c = c + 1 end
					end
					card.countLabel.Text = t > 0 and (c .. " / " .. t .. " an") or ""
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
		pageName.Text = page.name
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
		page.holder.ScrollBarThickness = 3
		page.holder.ScrollBarImageColor3 = UI.theme.accent
		page.holder.ScrollBarImageTransparency = 0.4
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
				hover.ZIndex = 3
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
					set = function(v) state = v and true or false paint(true) end,
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

				return { set = function(v)
					apply((v - minValue) / math.max(1, maxValue - minValue), false)
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
					b.Text = text
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
				-- to the label, or a long value truncates.
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

				local function refresh()
					local ok, text = pcall(getText)
					chipText.Text = ok and tostring(text) or "-"
				end
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

				local menu = frame(r.inner, UDim2.fromOffset(96, 0), UDim2.new(1, -96, 0, 20),
					UI.theme.input)
				menu.Visible = false
				menu.ZIndex = 20
				menu.ClipsDescendants = true
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
					item.Text = "  " .. tostring(choice)
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
						boxText.Text = tostring(choice)
						menu.Visible = false
						if callback then task.spawn(callback, choice) end
					end)
				end

				box.MouseButton1Click:Connect(function()
					menu.Visible = not menu.Visible
					arrow.Text = menu.Visible and "▲" or "▼"
				end)

				return { set = function(v) value = v boxText.Text = tostring(v) end }
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
				b.Text = string.upper(caption2 or "")
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
				local l = label(r.inner, text or "", 10, UI.font.mono, UI.theme.dimmer)
				l.Size = UDim2.new(1, 0, 0, 0)
				l.AutomaticSize = Enum.AutomaticSize.Y
				l.TextWrapped = true
				l.TextYAlignment = Enum.TextYAlignment.Top
				l.ZIndex = 5
				return { set = function(t) l.Text = t or "" end, label = l }
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
						local list = b
						if list == nil and type(a) == "table" and a[1] ~= nil then
							list = a
						end
						for i, l in ipairs(rowLabels) do
							local text = list and list[i] or ""
							l.Text = text
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
		local card = page:Card("CHANGELOG", 0):Accent():Icon(UI.icon.clock)
		card:Label("laedt ...")
		local body2 = card.rowHolder

		local function paint(list, err)
			for _, child in ipairs(body2:GetChildren()) do
				if child:IsA("Frame") then child:Destroy() end
			end
			if not list then
				local l = card:Label(err or "keine Verbindung zu GitHub")
				return
			end
			for _, entry in ipairs(list) do
				local r = card.row(entry.game, entry.summary, 70)
				r.title.TextColor3 = UI.theme.text
				r.title.Font = UI.font.heading
				-- newest commit gets the live dot, the rest a static one
				local dot = frame(r.inner, UDim2.fromOffset(6, 6),
					UDim2.fromOffset(-11, 5),
					entry == list[1] and UI.theme.accent or UI.theme.fainter)
				dot.ZIndex = 5
				corner(dot, 3)
				if entry == list[1] then registerPulse(dot, 2.2, 0.6, 0) end
				local age = label(r.inner, entry.when, 10, UI.font.mono, UI.theme.faint)
				age.Position = UDim2.new(1, -66, 0, 0)
				age.Size = UDim2.fromOffset(66, 14)
				age.TextXAlignment = Enum.TextXAlignment.Right
				age.ZIndex = 5
			end
			page:Fill()
		end

		-- Never on the main thread: an executor with no working http, or GitHub
		-- rate-limiting the IP, must leave the panel usable.
		task.spawn(function()
			local ok, list, err = pcall(UI.commits, options2.limit or 6)
			paint(ok and list or nil, ok and err or "GitHub nicht erreichbar")
		end)

		page.reload = function()
			task.spawn(function()
				local ok, list, err = pcall(UI.commits, options2.limit or 6)
				paint(ok and list or nil, ok and err or "GitHub nicht erreichbar")
			end)
		end
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
	if delta < 90 then return "gerade eben" end
	if delta < 5400 then return math.floor(delta / 60) .. " Min" end
	if delta < 172800 then return math.floor(delta / 3600) .. " Std" end
	return math.floor(delta / 86400) .. " Tage"
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
