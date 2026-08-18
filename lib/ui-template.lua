--!nocheck
-- ui-template.lua  --  the house UI for every script in this folder  --  seltonmt
--
--   local UI = loadstring(readfile("ui-template.lua"))()
--   local win  = UI.Window({ title = "SPEED", accentTitle = "MONKEY", subtitle = "seltonmt" })
--   local page = win:Page("FARM", UI.icon.bolt)
--   local card = page:Card("LOOP", 1)      -- 1 = left, 2 = right, 0 = full width
--   card:Toggle("Auto", CONFIG.auto, function(v) CONFIG.auto = v end, "hint")
--   local refresh = card:Stepper("Stage", getText, onStep)   -- returns a refresher
--   card:Slider("Rate", 2, 40, 12, function(v) ... end)
--   card:Dropdown("Mode", { "Fast", "Safe" }, "Fast", function(v) ... end)
--   card:Button("Unstuck", function() ... end, UI.theme.bad)
--   local out = card:Readout(12); out:set({ "STATUS", "  income 47.3K/s" })
--   win:SetStatus("213K wins   lvl 241   world 2")     -- the live header line
--
-- ==== v2 =====================================================================
-- The first version was a port of a Neverlose-style mock: flat slate blue on
-- near-black, no motion. This one keeps the layout that worked and every entry
-- point above unchanged, and replaces the surface: its own palette, gradients
-- instead of flat fills, and motion on everything the user can touch.
--
-- Palette is "neon dusk" - a violet-black base with a violet -> cyan accent ramp,
-- mint for good, amber for warn, rose for bad. Nothing in here is borrowed from
-- another menu; the colours are the panel's own identity.
--
-- Motion rules, so it stays quick rather than showy:
--   * anything you click answers within 120-180ms; nothing blocks input
--   * the toggle knob overshoots slightly (Back easing) because that reads as a
--     switch rather than a fade
--   * one shared Heartbeat rotates every accent gradient; adding a second driver
--     per element is what makes a Roblox panel stutter
--   * page changes fade and lift 10px, they do not slide sideways - sideways
--     motion makes the two-column grid look like it is being rebuilt
--
-- Layout, unchanged from v1 because it was the part that worked: a 78px icon
-- rail, a 224px nav column with the search box, then the content area with a
-- header carrying the live line, an "AKTIV n" chip bar, and a two-column card
-- grid with a full-width strip below it.
--
-- Implementation notes worth keeping:
--   * The card grid is NOT a UIGridLayout. A grid forces every cell to one size,
--     which fights AutomaticSize and clipped every card to a fixed height. Two
--     plain columns, each with its own UIListLayout, let cards size themselves.
--   * Do not nest AutomaticSize more than one level inside a UIListLayout. The
--     grid holder is sized by hand from max(column1, column2).
--   * Chips are keyed by an internal counter, not by their caption, so two
--     toggles that happen to share a label do not overwrite each other.
--   * Search hides rows, then any card with no visible row left, then dims the
--     nav entry of a page with no hit at all.

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local plr = Players.LocalPlayer

local UI = {}

-- Palette ---------------------------------------------------------------------
-- Every surface is one of five depths so the eye can tell nesting apart without
-- borders doing all the work: void < rail < window < card < input.
UI.theme = {
	void = Color3.fromHex("06050c"),
	rail = Color3.fromHex("0a0814"),
	sidebar = Color3.fromHex("0d0a19"),
	window = Color3.fromHex("110d1e"),
	header = Color3.fromHex("0f0b1b"),
	subBar = Color3.fromHex("0c0917"),
	card = Color3.fromHex("171227"),
	cardHover = Color3.fromHex("1d1731"),
	input = Color3.fromHex("140f24"),
	backdrop = Color3.fromHex("06050c"),

	-- the accent is a ramp, not a colour: violet into cyan
	accent = Color3.fromHex("8b5cf6"),
	accentAlt = Color3.fromHex("22d3ee"),
	accentHover = Color3.fromHex("a78bfa"),
	accentSoft = Color3.fromHex("d8caff"),

	-- tones that carry meaning
	good = Color3.fromHex("5eead4"),
	warn = Color3.fromHex("fbbf24"),
	bad = Color3.fromHex("fb7185"),

	text = Color3.fromHex("ffffff"),

	-- rgba() from the mock is a solid colour plus a transparency in Roblox, so the
	-- alphas live here rather than being guessed at every call site.
	lineAlpha = 0.9,
	dimAlpha = 0.5,
	fainterAlpha = 0.7,
}

UI.font = {
	heading = Enum.Font.GothamBold,
	body = Enum.Font.Gotham,
	mono = Enum.Font.Code,
}

-- Icon glyphs for the 78px rail. Roblox has no inline SVG, so the mock's icons
-- become single characters. Every key from v1 is still here; scripts index these
-- by name and a missing one would silently draw nothing.
UI.icon = {
	sliders = "≡", eye = "◉", target = "◎", shield = "◇",
	bolt = "⚡", gear = "⚙", list = "▤", chart = "▦",
	sword = "†", coin = "◍", flask = "◊", map = "◈",
	pickaxe = "⛏", bag = "▣", clock = "◷", flame = "✦",
	star = "✧", wave = "≈", grid = "⊞", spark = "❉",
}

-- Motion ----------------------------------------------------------------------
local EASE = {
	quick = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
	soft = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
	snap = TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
	slow = TweenInfo.new(0.3, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
}

local function tween(instance, info, props)
	local t = TweenService:Create(instance, info, props)
	t:Play()
	return t
end

-- One driver for every animated gradient in the panel. A per-element RunService
-- connection is what turns a Roblox menu into a stutter, so they all register
-- here and get stepped from a single Heartbeat.
local spinners = {}
local spinnerConn
local function registerSpin(gradient, speed, sweep)
	table.insert(spinners, { gradient = gradient, speed = speed or 24, sweep = sweep or 0 })
	if spinnerConn then return end
	local clock = 0
	spinnerConn = RunService.Heartbeat:Connect(function(dt)
		clock += dt
		for index = #spinners, 1, -1 do
			local entry = spinners[index]
			if not entry.gradient.Parent then
				table.remove(spinners, index)
			else
				entry.gradient.Rotation = (clock * entry.speed + entry.sweep) % 360
			end
		end
		if #spinners == 0 then
			spinnerConn:Disconnect()
			spinnerConn = nil
		end
	end)
end

-- Building blocks -------------------------------------------------------------

local function corner(instance, radius)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius or 8)
	c.Parent = instance
	return c
end

local function stroke(instance, alpha, color)
	local s = Instance.new("UIStroke")
	s.Color = color or UI.theme.text
	s.Transparency = alpha or UI.theme.lineAlpha
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = instance
	return s
end

-- The accent ramp as a gradient. `spin` makes it drift, which is what gives the
-- window edge and the active controls their slow shimmer.
local function accentGradient(instance, spin, a, b)
	local g = Instance.new("UIGradient")
	g.Color = ColorSequence.new(a or UI.theme.accent, b or UI.theme.accentAlt)
	g.Rotation = 25
	g.Parent = instance
	if spin then registerSpin(g, spin) end
	return g
end

-- A very slight top-to-bottom lift on a solid surface. Flat fills read as cheap
-- at this size; a 6% ramp is enough to give the card an edge without banding.
local function sheen(instance, strength)
	local g = Instance.new("UIGradient")
	g.Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(210, 210, 220))
	g.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1 - (strength or 0.06)),
		NumberSequenceKeypoint.new(1, 1),
	})
	g.Rotation = 90
	g.Parent = instance
	return g
end

local function label(parent, text, size, font, color, alpha)
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Text = text or ""
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextSize = size or 14
	l.Font = font or UI.font.body
	l.TextColor3 = color or UI.theme.text
	l.TextTransparency = alpha or 0
	l.Parent = parent
	return l
end

-- Window -----------------------------------------------------------------------

function UI.Window(options)
	options = options or {}

	local WIDTH = options.width or 880
	local HEIGHT = options.height or 560

	local gui = Instance.new("ScreenGui")
	gui.Name = options.name or "Panel"
	gui.ResetOnSpawn = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	pcall(function() gui.Parent = (gethui and gethui()) or game:GetService("CoreGui") end)
	if not gui.Parent then gui.Parent = plr:WaitForChild("PlayerGui") end

	local root = Instance.new("Frame")
	root.Size = UDim2.fromOffset(WIDTH, HEIGHT)
	root.Position = UDim2.new(0, 40, 0.5, -HEIGHT / 2)
	root.BackgroundColor3 = UI.theme.window
	root.BorderSizePixel = 0
	root.Active = true
	root.Draggable = true
	root.ClipsDescendants = true
	root.Parent = gui
	corner(root, 18)

	-- The window edge is the one place the accent ramp is always visible, so it
	-- gets the slow drift. Two strokes: a dark one for contrast against a bright
	-- game, the gradient one on top.
	stroke(root, 0.55, UI.theme.void)
	local edge = Instance.new("UIStroke")
	edge.Thickness = 1
	edge.Transparency = 0.35
	edge.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	edge.Parent = root
	accentGradient(edge, 14)

	-- Opening animation. UIScale rather than Size so the layout inside never has
	-- to reflow mid-tween.
	local scale = Instance.new("UIScale")
	scale.Scale = 0.94
	scale.Parent = root
	tween(scale, EASE.slow, { Scale = 1 })

	local window = {
		gui = gui, root = root,
		pages = {}, chips = {}, searchable = {}, cards = {},
		chipCount = 0,
	}

	-- Sidebar ------------------------------------------------------------------
	--
	-- v2.1 dropped the 78px icon rail. It duplicated the nav list one column to
	-- the left, it was dead space for any script with a single page, and its
	-- `railFill` corner patch was a sibling inside the rail's own UIListLayout -
	-- so the layout treated a full-height frame as the first list item and pushed
	-- the badge and every rail entry off the bottom. The rail rendered as an empty
	-- strip. Removing it also hands 78px back to the card grid, which is what was
	-- truncating the hint lines.
	local SIDEBAR = 240

	local sidebar = Instance.new("Frame")
	sidebar.Size = UDim2.new(0, SIDEBAR, 1, 0)
	sidebar.BackgroundColor3 = UI.theme.sidebar
	sidebar.BorderSizePixel = 0
	sidebar.Parent = root
	corner(sidebar, 18)

	local sidebarFill = Instance.new("Frame")   -- squares off the right-hand corners
	sidebarFill.Size = UDim2.new(0, 18, 1, 0)
	sidebarFill.Position = UDim2.new(1, -18, 0, 0)
	sidebarFill.BackgroundColor3 = UI.theme.sidebar
	sidebarFill.BorderSizePixel = 0
	sidebarFill.Parent = sidebar

	-- The badge the scripts pass moves here now that the rail is gone.
	local badge = Instance.new("Frame")
	badge.Size = UDim2.fromOffset(30, 30)
	badge.Position = UDim2.new(0, 18, 0, 20)
	badge.BackgroundColor3 = UI.theme.accent
	badge.BorderSizePixel = 0
	badge.Parent = sidebar
	corner(badge, 10)
	accentGradient(badge, 20)
	local badgeText = label(badge, options.badge or "◈", 15, UI.font.heading, UI.theme.void)
	badgeText.Size = UDim2.fromScale(1, 1)
	badgeText.TextXAlignment = Enum.TextXAlignment.Center

	local brand = label(sidebar, options.title or "PANEL", 19, UI.font.heading)
	brand.Size = UDim2.new(1, -66, 0, 26)
	brand.Position = UDim2.new(0, 58, 0, 22)

	-- The accented half of the title is a real gradient rather than a RichText
	-- colour, so it drifts with the rest of the accent surfaces.
	local brandAccent = label(sidebar, options.accentTitle or "", 19, UI.font.heading)
	brandAccent.Size = UDim2.new(1, -66, 0, 26)
	-- Measured with TextService, not by reading TextBounds off a hidden label:
	-- TextBounds on an instance that has never been rendered can come back as
	-- zero on the first frame and the two halves of the title then overlap.
	local titleWidth = game:GetService("TextService"):GetTextSize(
		options.title or "PANEL", 19, UI.font.heading, Vector2.new(1000, 100)).X
	brandAccent.Position = UDim2.new(0, 58 + titleWidth, 0, 22)
	accentGradient(brandAccent, 18)

	local searchWrap = Instance.new("Frame")
	searchWrap.Size = UDim2.new(1, -28, 0, 34)
	searchWrap.Position = UDim2.new(0, 14, 0, 58)
	searchWrap.BackgroundColor3 = UI.theme.input
	searchWrap.BorderSizePixel = 0
	searchWrap.Parent = sidebar
	corner(searchWrap, 10)
	local searchEdge = stroke(searchWrap, 0.9)

	local search = Instance.new("TextBox")
	search.Size = UDim2.new(1, -34, 1, 0)
	search.Position = UDim2.new(0, 12, 0, 0)
	search.BackgroundTransparency = 1
	search.PlaceholderText = "Einstellung suchen…"
	search.Text = ""
	search.TextXAlignment = Enum.TextXAlignment.Left
	search.TextColor3 = UI.theme.text
	search.PlaceholderColor3 = UI.theme.accentSoft
	search.Font = UI.font.body
	search.TextSize = 13
	search.ClearTextOnFocus = false
	search.Parent = searchWrap
	window.search = search

	search.Focused:Connect(function()
		tween(searchEdge, EASE.quick, { Transparency = 0.35, Color = UI.theme.accent })
	end)
	search.FocusLost:Connect(function()
		tween(searchEdge, EASE.quick, { Transparency = 0.9, Color = UI.theme.text })
	end)

	local searchClear = Instance.new("TextButton")
	searchClear.Size = UDim2.fromOffset(22, 22)
	searchClear.Position = UDim2.new(1, -28, 0.5, -11)
	searchClear.BackgroundTransparency = 1
	searchClear.Text = "×"
	searchClear.TextColor3 = UI.theme.text
	searchClear.TextTransparency = UI.theme.dimAlpha
	searchClear.Font = UI.font.heading
	searchClear.TextSize = 16
	searchClear.Parent = searchWrap
	searchClear.MouseButton1Click:Connect(function()
		search.Text = ""
		search:ReleaseFocus()
	end)

	local navScroll = Instance.new("ScrollingFrame")
	navScroll.Size = UDim2.new(1, -24, 1, -170)
	navScroll.Position = UDim2.new(0, 12, 0, 102)
	navScroll.BackgroundTransparency = 1
	navScroll.BorderSizePixel = 0
	navScroll.ScrollBarThickness = 2
	navScroll.ScrollBarImageColor3 = UI.theme.accent
	navScroll.ScrollBarImageTransparency = 0.5
	navScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	navScroll.CanvasSize = UDim2.new()
	navScroll.Parent = sidebar

	local navList = Instance.new("UIListLayout")
	navList.Padding = UDim.new(0, 4)
	navList.SortOrder = Enum.SortOrder.LayoutOrder
	navList.Parent = navScroll

	local footer = Instance.new("Frame")
	footer.Size = UDim2.new(1, 0, 0, 62)
	footer.Position = UDim2.new(0, 0, 1, -62)
	footer.BackgroundTransparency = 1
	footer.Parent = sidebar
	local footLine = Instance.new("Frame")
	footLine.Size = UDim2.new(1, 0, 0, 1)
	footLine.BackgroundColor3 = UI.theme.text
	footLine.BackgroundTransparency = UI.theme.lineAlpha
	footLine.BorderSizePixel = 0
	footLine.Parent = footer

	local avatar = Instance.new("Frame")
	avatar.Size = UDim2.fromOffset(36, 36)
	avatar.Position = UDim2.new(0, 18, 0, 13)
	avatar.BackgroundColor3 = UI.theme.accent
	avatar.BorderSizePixel = 0
	avatar.Parent = footer
	corner(avatar, 18)
	accentGradient(avatar, 12)
	local avatarText = label(avatar, string.sub(plr.Name, 1, 1):upper(), 15,
		UI.font.heading, UI.theme.void)
	avatarText.Size = UDim2.fromScale(1, 1)
	avatarText.TextXAlignment = Enum.TextXAlignment.Center

	local userName = label(footer, plr.Name, 14, UI.font.body)
	userName.Size = UDim2.new(1, -70, 0, 16)
	userName.Position = UDim2.new(0, 64, 0, 15)
	userName.TextTruncate = Enum.TextTruncate.AtEnd
	local userSub = label(footer, options.subtitle or "seltonmt", 12,
		UI.font.body, UI.theme.accentSoft, 0.35)
	userSub.Size = UDim2.new(1, -70, 0, 14)
	userSub.Position = UDim2.new(0, 64, 0, 32)

	-- Content ------------------------------------------------------------------
	local content = Instance.new("Frame")
	content.Size = UDim2.new(1, -SIDEBAR, 1, 0)
	content.Position = UDim2.new(0, SIDEBAR, 0, 0)
	content.BackgroundTransparency = 1
	content.Parent = root

	local head = Instance.new("Frame")
	head.Size = UDim2.new(1, 0, 0, 66)
	head.BackgroundColor3 = UI.theme.header
	head.BorderSizePixel = 0
	head.Parent = content

	-- A 2px accent ramp along the top edge. It is the only thing in the header
	-- that moves, which keeps the live line readable while still looking alive.
	local headBar = Instance.new("Frame")
	headBar.Size = UDim2.new(1, 0, 0, 2)
	headBar.BackgroundColor3 = UI.theme.accent
	headBar.BorderSizePixel = 0
	headBar.Parent = head
	accentGradient(headBar, 30)

	local headTitle = label(head, options.title or "PANEL", 19, UI.font.heading)
	headTitle.Size = UDim2.new(1, -90, 0, 22)
	headTitle.Position = UDim2.new(0, 26, 0, 12)
	window.headTitle = headTitle

	-- The live line. Kept in the header on purpose: it stays readable while the
	-- window is collapsed, which is the whole point of collapsing it.
	local headSub = label(head, options.subtitle or "", 12, UI.font.mono,
		UI.theme.accentSoft, 0.25)
	headSub.Size = UDim2.new(1, -90, 0, 15)
	headSub.Position = UDim2.new(0, 26, 0, 36)
	headSub.TextTruncate = Enum.TextTruncate.AtEnd
	window.headSub = headSub

	local collapseButton = Instance.new("TextButton")
	collapseButton.Size = UDim2.fromOffset(28, 24)
	collapseButton.Position = UDim2.new(1, -44, 0, 14)
	collapseButton.BackgroundColor3 = UI.theme.input
	collapseButton.BorderSizePixel = 0
	collapseButton.Text = "–"
	collapseButton.TextColor3 = UI.theme.accentSoft
	collapseButton.Font = UI.font.heading
	collapseButton.TextSize = 15
	collapseButton.AutoButtonColor = false
	collapseButton.Parent = head
	corner(collapseButton, 8)
	local collapseEdge = stroke(collapseButton, 0.85)
	collapseButton.MouseEnter:Connect(function()
		tween(collapseEdge, EASE.quick, { Transparency = 0.4, Color = UI.theme.accent })
	end)
	collapseButton.MouseLeave:Connect(function()
		tween(collapseEdge, EASE.quick, { Transparency = 0.85, Color = UI.theme.text })
	end)

	-- Chip bar -----------------------------------------------------------------
	local chipBar = Instance.new("Frame")
	chipBar.Size = UDim2.new(1, 0, 0, 36)
	chipBar.Position = UDim2.new(0, 0, 0, 66)
	chipBar.BackgroundColor3 = UI.theme.subBar
	chipBar.BorderSizePixel = 0
	chipBar.Parent = content

	local chipCaption = label(chipBar, "AKTIV 0", 10, UI.font.heading,
		UI.theme.accent, 0.15)
	chipCaption.Size = UDim2.fromOffset(70, 14)
	chipCaption.Position = UDim2.new(0, 26, 0, 11)
	window.chipCaption = chipCaption

	local chipHolder = Instance.new("ScrollingFrame")
	chipHolder.Size = UDim2.new(1, -134, 1, -6)
	chipHolder.Position = UDim2.new(0, 96, 0, 3)
	chipHolder.BackgroundTransparency = 1
	chipHolder.BorderSizePixel = 0
	chipHolder.ClipsDescendants = true
	chipHolder.ScrollBarThickness = 0
	chipHolder.ScrollingDirection = Enum.ScrollingDirection.X
	chipHolder.AutomaticCanvasSize = Enum.AutomaticSize.X
	chipHolder.CanvasSize = UDim2.new()
	chipHolder.Parent = chipBar

	-- With nine toggles on the chip bar the row runs past the window edge and the
	-- last chip reads as a rendering fault rather than as "there is more". A fade
	-- on the right edge plus a count says both, and the strip still scrolls.
	local chipFade = Instance.new("Frame")
	chipFade.Size = UDim2.fromOffset(46, 36)
	chipFade.Position = UDim2.new(1, -46, 0, 0)
	chipFade.BackgroundColor3 = UI.theme.subBar
	chipFade.BorderSizePixel = 0
	chipFade.ZIndex = 3
	chipFade.Parent = chipBar
	local fadeGradient = Instance.new("UIGradient")
	fadeGradient.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(1, 0),
	})
	fadeGradient.Parent = chipFade

	local chipMore = label(chipBar, "", 10, UI.font.heading, UI.theme.accent, 0.2)
	chipMore.Size = UDim2.fromOffset(34, 14)
	chipMore.Position = UDim2.new(1, -36, 0, 11)
	chipMore.TextXAlignment = Enum.TextXAlignment.Right
	chipMore.ZIndex = 4
	window.chipMore = chipMore
	local chipLayout = Instance.new("UIListLayout")
	chipLayout.FillDirection = Enum.FillDirection.Horizontal
	chipLayout.Padding = UDim.new(0, 7)
	chipLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	chipLayout.SortOrder = Enum.SortOrder.LayoutOrder
	chipLayout.Parent = chipHolder
	window.chipHolder = chipHolder

	local pageHolder = Instance.new("Frame")
	pageHolder.Size = UDim2.new(1, 0, 1, -102)
	pageHolder.Position = UDim2.new(0, 0, 0, 102)
	pageHolder.BackgroundTransparency = 1
	pageHolder.Parent = content
	window.pageHolder = pageHolder

	-- Behaviour ----------------------------------------------------------------

	-- Search hides rows, then any card with no visible row, then dims the nav
	-- entry of a page that has no hit at all.
	local function applyFilter()
		local needle = search.Text:lower()
		for _, entry in ipairs(window.searchable) do
			entry.instance.Visible = needle == ""
				or entry.caption:find(needle, 1, true) ~= nil
		end
		for _, card in ipairs(window.cards) do
			local visible = needle == ""
			if not visible then
				for _, entry in ipairs(card.entries) do
					if entry.instance.Visible then visible = true break end
				end
			end
			card.frame.Visible = visible
		end
		for _, page in ipairs(window.pages) do
			local hit = needle == ""
			if not hit then
				for _, card in ipairs(page.cards) do
					if card.frame.Visible then hit = true break end
				end
			end
			page.navText.TextTransparency = hit and
				(window.activePage == page and 0 or UI.theme.dimAlpha) or 0.85
		end
	end
	search:GetPropertyChangedSignal("Text"):Connect(applyFilter)

	local collapsed = false
	collapseButton.MouseButton1Click:Connect(function()
		collapsed = not collapsed
		collapseButton.Text = collapsed and "+" or "–"
		sidebar.Visible = not collapsed
		chipBar.Visible = not collapsed
		pageHolder.Visible = not collapsed
		content.Position = collapsed and UDim2.new() or UDim2.new(0, SIDEBAR, 0, 0)
		content.Size = collapsed and UDim2.new(1, 0, 1, 0) or UDim2.new(1, -SIDEBAR, 1, 0)
		tween(root, EASE.soft, {
			Size = collapsed and UDim2.fromOffset(WIDTH, 66) or UDim2.fromOffset(WIDTH, HEIGHT),
		})
	end)

	-- Hiding fades and shrinks rather than flicking Visible, so RightShift does
	-- not look like the panel crashed.
	local shown = true
	local function setShown(value)
		if shown == value then return end
		shown = value
		if shown then
			root.Visible = true
			scale.Scale = 0.94
			tween(scale, EASE.slow, { Scale = 1 })
		else
			local t = tween(scale, EASE.soft, { Scale = 0.94 })
			t.Completed:Connect(function()
				if not shown then root.Visible = false end
			end)
		end
	end

	UserInputService.InputBegan:Connect(function(input, typing)
		if typing then return end
		if input.KeyCode == (options.hotkey or Enum.KeyCode.RightShift) then
			setShown(not shown)
		end
	end)

	function window:Refresh()
		local active = 0
		for _, chip in ipairs(self.chips) do
			local on = chip.get()
			if on ~= chip.shown then
				chip.shown = on
				if on then
					chip.frame.Visible = true
					chip.scale.Scale = 0.6
					tween(chip.scale, EASE.snap, { Scale = 1 })
				else
					local t = tween(chip.scale, EASE.quick, { Scale = 0.6 })
					t.Completed:Connect(function()
						if not chip.shown then chip.frame.Visible = false end
					end)
				end
			end
			if on then active += 1 end
		end
		self.chipCaption.Text = "AKTIV " .. active

		-- Counted a frame later on purpose: the chips were only just made visible,
		-- so their AbsolutePosition is still last frame's until the layout runs.
		task.defer(function()
			if not self.chipMore.Parent then return end
			local right = chipHolder.AbsolutePosition.X + chipHolder.AbsoluteSize.X
			local hidden = 0
			for _, chip in ipairs(self.chips) do
				if chip.frame.Visible and
					chip.frame.AbsolutePosition.X + chip.frame.AbsoluteSize.X > right then
					hidden += 1
				end
			end
			self.chipMore.Text = hidden > 0 and ("+" .. hidden) or ""
		end)
	end

	function window:SetStatus(text) self.headSub.Text = text end
	function window:Destroy() gui:Destroy() end

	-- Page ---------------------------------------------------------------------
	function window:Page(name, iconGlyph)
		local page = Instance.new("ScrollingFrame")
		page.Size = UDim2.new(1, -44, 1, -16)
		page.Position = UDim2.new(0, 24, 0, 8)
		page.BackgroundTransparency = 1
		page.BorderSizePixel = 0
		page.ScrollBarThickness = 3
		page.ScrollBarImageColor3 = UI.theme.accent
		page.ScrollBarImageTransparency = 0.55
		page.AutomaticCanvasSize = Enum.AutomaticSize.Y
		page.CanvasSize = UDim2.new()
		page.Visible = false
		page.Parent = pageHolder

		-- A page stacks two blocks: the two-column card grid, and below it a
		-- full-width strip for cards that need the room (log lines, wide tables).
		local pageList = Instance.new("UIListLayout")
		pageList.Padding = UDim.new(0, 14)
		pageList.SortOrder = Enum.SortOrder.LayoutOrder
		pageList.Parent = page

		-- The grid holder is sized by hand from its two columns. Nesting
		-- AutomaticSize inside AutomaticSize inside a UIListLayout does resolve
		-- eventually but not reliably on the first frame, and a collapsed grid
		-- pushes the full-width strip over the cards.
		local gridHolder = Instance.new("Frame")
		gridHolder.Name = "Grid"
		gridHolder.Size = UDim2.new(1, 0, 0, 0)
		gridHolder.BackgroundTransparency = 1
		gridHolder.LayoutOrder = 1
		gridHolder.Parent = page

		-- Two hand-built columns, not a UIGridLayout: a grid pins every cell to
		-- one height and cards have to size themselves to their rows.
		local columns = {}
		for index = 1, 2 do
			local column = Instance.new("Frame")
			column.Name = "Column" .. index
			column.Size = UDim2.new(0.5, -8, 0, 0)
			column.Position = UDim2.new((index - 1) * 0.5, index == 1 and 0 or 8, 0, 0)
			column.AutomaticSize = Enum.AutomaticSize.Y
			column.BackgroundTransparency = 1
			column.Parent = gridHolder

			local columnList = Instance.new("UIListLayout")
			columnList.Padding = UDim.new(0, 14)
			columnList.SortOrder = Enum.SortOrder.LayoutOrder
			columnList.Parent = column

			columns[index] = column
		end

		local function fitGrid()
			gridHolder.Size = UDim2.new(1, 0, 0,
				math.max(columns[1].AbsoluteSize.Y, columns[2].AbsoluteSize.Y))
		end
		columns[1]:GetPropertyChangedSignal("AbsoluteSize"):Connect(fitGrid)
		columns[2]:GetPropertyChangedSignal("AbsoluteSize"):Connect(fitGrid)

		local fullHolder = Instance.new("Frame")
		fullHolder.Name = "Full"
		fullHolder.Size = UDim2.new(1, 0, 0, 0)
		fullHolder.AutomaticSize = Enum.AutomaticSize.Y
		fullHolder.BackgroundTransparency = 1
		fullHolder.LayoutOrder = 2
		fullHolder.Parent = page
		local fullList = Instance.new("UIListLayout")
		fullList.Padding = UDim.new(0, 14)
		fullList.SortOrder = Enum.SortOrder.LayoutOrder
		fullList.Parent = fullHolder
		columns[0] = fullHolder

		local navEntry = Instance.new("TextButton")
		navEntry.Size = UDim2.new(1, -4, 0, 34)
		navEntry.BackgroundColor3 = UI.theme.accent
		navEntry.BackgroundTransparency = 1
		navEntry.BorderSizePixel = 0
		navEntry.Text = ""
		navEntry.AutoButtonColor = false
		navEntry.LayoutOrder = #self.pages + 1
		navEntry.Parent = navScroll
		corner(navEntry, 10)

		-- The active marker is a bar that grows out of the left edge rather than a
		-- highlight that appears - growth reads as "this one", a fade reads as
		-- "something changed somewhere".
		local navMark = Instance.new("Frame")
		navMark.Size = UDim2.fromOffset(3, 0)
		navMark.Position = UDim2.new(0, 0, 0.5, 0)
		navMark.AnchorPoint = Vector2.new(0, 0.5)
		navMark.BackgroundColor3 = UI.theme.accent
		navMark.BorderSizePixel = 0
		navMark.Parent = navEntry
		corner(navMark, 2)
		accentGradient(navMark, 40)

		local glyph = label(navEntry, iconGlyph or UI.icon.sliders, 14,
			UI.font.body, UI.theme.accent, 0.3)
		glyph.Size = UDim2.fromOffset(18, 34)
		glyph.Position = UDim2.new(0, 12, 0, 0)
		glyph.TextXAlignment = Enum.TextXAlignment.Center

		local navText = label(navEntry, name, 14, UI.font.body,
			UI.theme.text, UI.theme.dimAlpha)
		navText.Size = UDim2.new(1, -44, 1, 0)
		navText.Position = UDim2.new(0, 38, 0, 0)

		local pageObject = {
			frame = page, name = name, cards = {}, window = self,
			navEntry = navEntry, navText = navText,
			columns = columns, nextColumn = 1,
		}

		local function select()
			for _, other in ipairs(self.pages) do
				if other ~= pageObject then
					other.frame.Visible = false
					tween(other.navEntry, EASE.quick, { BackgroundTransparency = 1 })
					tween(other.navMark, EASE.quick, { Size = UDim2.fromOffset(3, 0) })
					tween(other.navText, EASE.quick, { TextTransparency = UI.theme.dimAlpha })
					tween(other.glyph, EASE.quick, { TextTransparency = 0.3 })
				end
			end
			page.Visible = true
			tween(navEntry, EASE.soft, { BackgroundTransparency = 0.9 })
			tween(navMark, EASE.snap, { Size = UDim2.fromOffset(3, 20) })
			tween(navText, EASE.quick, { TextTransparency = 0 })
			tween(glyph, EASE.quick, { TextTransparency = 0 })
			self.activePage = pageObject
			self.headTitle.Text = name

			-- fade and lift, never slide sideways: sideways motion on a two-column
			-- grid looks like the layout is being rebuilt
			page.Position = UDim2.new(0, 24, 0, 18)
			tween(page, EASE.slow, { Position = UDim2.new(0, 24, 0, 8) })
		end
		pageObject.select = select
		pageObject.navMark = navMark
		pageObject.glyph = glyph

		navEntry.MouseButton1Click:Connect(select)
		navEntry.MouseEnter:Connect(function()
			if self.activePage ~= pageObject then
				tween(navEntry, EASE.quick, { BackgroundTransparency = 0.94 })
				tween(navText, EASE.quick, { TextTransparency = 0.2 })
			end
		end)
		navEntry.MouseLeave:Connect(function()
			if self.activePage ~= pageObject then
				tween(navEntry, EASE.quick, { BackgroundTransparency = 1 })
				tween(navText, EASE.quick, { TextTransparency = UI.theme.dimAlpha })
			end
		end)
		-- Card -----------------------------------------------------------------
		-- column: 1 = left, 2 = right, 0 = a full-width card below the grid.
		-- Omitted, cards alternate left/right.
		function pageObject:Card(cardTitle, column)
			local host
			if column == 0 then
				host = self.columns[0]
			else
				if column then self.nextColumn = math.clamp(column, 1, 2) end
				host = self.columns[self.nextColumn]
				self.nextColumn = self.nextColumn == 1 and 2 or 1
			end

			local card = Instance.new("Frame")
			card.Name = cardTitle
			card.BackgroundColor3 = UI.theme.card
			card.BorderSizePixel = 0
			card.AutomaticSize = Enum.AutomaticSize.Y
			card.Size = UDim2.new(1, 0, 0, 0)
			card.LayoutOrder = #host:GetChildren()
			card.Parent = host
			corner(card, 12)
			sheen(card, 0.05)
			local cardEdge = stroke(card, 0.88)

			card.MouseEnter:Connect(function()
				tween(card, EASE.quick, { BackgroundColor3 = UI.theme.cardHover })
				tween(cardEdge, EASE.quick, { Transparency = 0.62, Color = UI.theme.accent })
			end)
			card.MouseLeave:Connect(function()
				tween(card, EASE.soft, { BackgroundColor3 = UI.theme.card })
				tween(cardEdge, EASE.soft, { Transparency = 0.88, Color = UI.theme.text })
			end)

			local cardList = Instance.new("UIListLayout")
			cardList.SortOrder = Enum.SortOrder.LayoutOrder
			cardList.Parent = card

			local cardHead = Instance.new("Frame")
			cardHead.Size = UDim2.new(1, 0, 0, 38)
			cardHead.BackgroundTransparency = 1
			cardHead.LayoutOrder = 0
			cardHead.Parent = card

			-- a small accent tick before the caption, so a card reads as a titled
			-- block instead of a floating rectangle
			local tick = Instance.new("Frame")
			tick.Size = UDim2.fromOffset(3, 11)
			tick.Position = UDim2.new(0, 16, 0.5, -6)
			tick.BackgroundColor3 = UI.theme.accent
			tick.BorderSizePixel = 0
			tick.Parent = cardHead
			corner(tick, 2)
			accentGradient(tick, 34)

			local headLabel = label(cardHead, string.upper(cardTitle), 11, UI.font.heading,
				UI.theme.text, 0.42)
			headLabel.Size = UDim2.new(1, -40, 1, 0)
			headLabel.Position = UDim2.new(0, 26, 0, 0)

			local divider = Instance.new("Frame")
			divider.Size = UDim2.new(1, 0, 0, 1)
			divider.Position = UDim2.new(0, 0, 1, -1)
			divider.BackgroundColor3 = UI.theme.text
			divider.BackgroundTransparency = UI.theme.lineAlpha
			divider.BorderSizePixel = 0
			divider.Parent = cardHead

			local body = Instance.new("Frame")
			body.Size = UDim2.new(1, 0, 0, 0)
			body.AutomaticSize = Enum.AutomaticSize.Y
			body.BackgroundTransparency = 1
			body.LayoutOrder = 1
			body.Parent = card
			local bodyList = Instance.new("UIListLayout")
			bodyList.Padding = UDim.new(0, 3)
			bodyList.SortOrder = Enum.SortOrder.LayoutOrder
			bodyList.Parent = body
			local pad = Instance.new("UIPadding")
			pad.PaddingTop = UDim.new(0, 9)
			pad.PaddingBottom = UDim.new(0, 13)
			pad.PaddingLeft = UDim.new(0, 16)
			pad.PaddingRight = UDim.new(0, 16)
			pad.Parent = body

			local cardObject = { frame = card, body = body, rows = 0, entries = {} }
			table.insert(self.cards, cardObject)
			table.insert(window.cards, cardObject)

			local function register(instance, caption)
				local entry = { instance = instance, caption = caption:lower() }
				table.insert(window.searchable, entry)
				table.insert(cardObject.entries, entry)
			end

			-- A row is caption (+ optional hint) on the left, control on the right.
			--
			-- The hint used to get `1, -120` like the caption, which on a card in
			-- the two-column grid left it about 125px - every hint longer than four
			-- words was truncated to "Red x1.5 @1K … Void…". The control only sits
			-- next to the CAPTION line, so the hint runs the full width underneath
			-- it and wraps to two lines instead. The caption keeps the -120.
			local HINT_LINES = 2
			local function row(text, hint, tone)
				cardObject.rows += 1
				local hintHeight = hint and (14 * HINT_LINES) or 0
				local holder = Instance.new("Frame")
				holder.Size = UDim2.new(1, 0, 0, hint and (22 + hintHeight + 6) or 32)
				holder.BackgroundTransparency = 1
				holder.LayoutOrder = cardObject.rows
				holder.Parent = body

				local name = label(holder, text, 13, UI.font.body, tone or UI.theme.text)
				name.Size = UDim2.new(1, -120, 0, hint and 20 or 32)
				name.Position = UDim2.new(0, 0, 0, hint and 2 or 0)
				name.TextTruncate = Enum.TextTruncate.AtEnd
				if hint then
					local sub = label(holder, hint, 11, UI.font.body,
						UI.theme.text, UI.theme.fainterAlpha)
					sub.Size = UDim2.new(1, -4, 0, hintHeight)
					sub.Position = UDim2.new(0, 0, 0, 22)
					sub.TextWrapped = true
					sub.TextYAlignment = Enum.TextYAlignment.Top
					sub.TextTruncate = Enum.TextTruncate.AtEnd
				end

				register(holder, text)
				-- Controls anchor to the caption line, not to the middle of the row:
				-- with a two-line hint below, a vertically centred toggle drifts down
				-- into the hint text and stops lining up with what it belongs to.
				return holder, hint and 11 or nil
			end

			-- x is the offset from the row's right edge, anchor is what row()
			-- returned, h the control's height.
			local function place(x, anchor, h)
				if anchor then return UDim2.new(1, x, 0, anchor - h / 2) end
				return UDim2.new(1, x, 0.5, -h / 2)
			end

			function cardObject:Toggle(text, initial, callback, hint, tone)
				local holder, anchor = row(text, hint, tone)
				local state = initial and true or false
				local shade = tone or UI.theme.accent

				-- A thin bar on the left doubles as the state indicator, so the
				-- setting reads at a glance without looking at the pill.
				local mark = Instance.new("Frame")
				mark.Size = UDim2.fromOffset(2, state and 16 or 6)
				mark.Position = anchor and UDim2.new(0, -9, 0, anchor)
					or UDim2.new(0, -9, 0.5, 0)
				mark.AnchorPoint = Vector2.new(0, 0.5)
				mark.BackgroundColor3 = shade
				mark.BackgroundTransparency = state and 0 or 0.8
				mark.BorderSizePixel = 0
				mark.Parent = holder
				corner(mark, 1)

				local pill = Instance.new("TextButton")
				pill.Size = UDim2.fromOffset(40, 21)
				pill.Position = place(-40, anchor, 21)
				pill.BackgroundColor3 = state and shade or UI.theme.input
				pill.BorderSizePixel = 0
				pill.Text = ""
				pill.AutoButtonColor = false
				pill.Parent = holder
				corner(pill, 11)
				local pillEdge = stroke(pill, state and 0.5 or 0.88, state and shade or UI.theme.text)

				-- The glow only exists while the toggle is on. Building it up front
				-- and hiding it keeps the tween from allocating on every click.
				local glow = Instance.new("UIStroke")
				glow.Thickness = 3
				glow.Color = shade
				glow.Transparency = state and 0.82 or 1
				glow.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
				glow.Parent = pill

				local knob = Instance.new("Frame")
				knob.Size = UDim2.fromOffset(15, 15)
				knob.Position = state and UDim2.new(1, -18, 0, 3) or UDim2.new(0, 3, 0, 3)
				knob.BackgroundColor3 = state and UI.theme.void or UI.theme.text
				knob.BackgroundTransparency = state and 0 or 0.3
				knob.BorderSizePixel = 0
				knob.Parent = pill
				corner(knob, 8)

				-- the chip that appears in the AKTIV bar while this is on
				window.chipCount += 1
				local chip = Instance.new("Frame")
				chip.Size = UDim2.fromOffset(0, 24)
				chip.AutomaticSize = Enum.AutomaticSize.X
				chip.BackgroundColor3 = shade
				chip.BackgroundTransparency = 0.86
				chip.BorderSizePixel = 0
				chip.Visible = state
				chip.LayoutOrder = window.chipCount
				chip.Parent = window.chipHolder
				corner(chip, 12)
				stroke(chip, 0.62, shade)
				local chipScale = Instance.new("UIScale")
				chipScale.Scale = state and 1 or 0.6
				chipScale.Parent = chip
				local chipText = label(chip, text, 11, UI.font.body, shade)
				chipText.Size = UDim2.new(0, 0, 1, 0)
				chipText.AutomaticSize = Enum.AutomaticSize.X
				chipText.Position = UDim2.new(0, 11, 0, 0)
				local chipPad = Instance.new("UIPadding")
				chipPad.PaddingRight = UDim.new(0, 22)
				chipPad.Parent = chip

				table.insert(window.chips, {
					frame = chip, scale = chipScale, shown = state,
					get = function() return state end,
				})

				local function apply()
					tween(pill, EASE.soft, {
						BackgroundColor3 = state and shade or UI.theme.input,
					})
					tween(knob, EASE.snap, {
						Position = state and UDim2.new(1, -18, 0, 3) or UDim2.new(0, 3, 0, 3),
						BackgroundColor3 = state and UI.theme.void or UI.theme.text,
						BackgroundTransparency = state and 0 or 0.3,
					})
					tween(pillEdge, EASE.soft, {
						Transparency = state and 0.5 or 0.88,
						Color = state and shade or UI.theme.text,
					})
					tween(glow, EASE.soft, { Transparency = state and 0.82 or 1 })
					tween(mark, EASE.snap, {
						Size = UDim2.fromOffset(2, state and 16 or 6),
						BackgroundTransparency = state and 0 or 0.8,
					})
					window:Refresh()
				end

				pill.MouseButton1Click:Connect(function()
					state = not state
					apply()
					if callback then callback(state) end
				end)

				local handle = {}
				function handle:set(value, silent)
					state = value and true or false
					apply()
					if callback and not silent then callback(state) end
				end
				function handle:get() return state end
				return handle
			end

			-- The stepper: a centred value chip between − and +. getText is a
			-- function so the caller keeps ownership of the value.
			function cardObject:Stepper(text, getText, onStep, hint)
				local holder, anchor = row(text, hint)

				local box = Instance.new("Frame")
				box.Size = UDim2.fromOffset(60, 22)
				box.Position = place(-82, anchor, 22)
				box.BackgroundColor3 = UI.theme.input
				box.BorderSizePixel = 0
				box.Parent = holder
				corner(box, 7)
				stroke(box, 0.88)

				local value = label(box, tostring(getText()), 11, UI.font.mono,
					UI.theme.accentSoft)
				value.Size = UDim2.new(1, -6, 1, 0)
				value.Position = UDim2.new(0, 3, 0, 0)
				value.TextXAlignment = Enum.TextXAlignment.Center
				value.TextTruncate = Enum.TextTruncate.AtEnd

				-- The value flashes to full accent on change. Without it a stepper
				-- that lands on a similar-looking number reads as "did not react".
				local function refresh()
					value.Text = tostring(getText())
					value.TextColor3 = UI.theme.accent
					tween(value, EASE.slow, { TextColor3 = UI.theme.accentSoft })
				end

				local function stepButton(glyphText, x, delta)
					local b = Instance.new("TextButton")
					b.Size = UDim2.fromOffset(22, 22)
					b.Position = place(x, anchor, 22)
					b.BackgroundColor3 = UI.theme.input
					b.BorderSizePixel = 0
					b.Text = glyphText
					b.TextColor3 = UI.theme.accent
					b.Font = UI.font.heading
					b.TextSize = 15
					b.AutoButtonColor = false
					b.Parent = holder
					corner(b, 7)
					local edge = stroke(b, 0.88)
					local bScale = Instance.new("UIScale")
					bScale.Parent = b
					b.MouseEnter:Connect(function()
						tween(b, EASE.quick, { TextColor3 = UI.theme.accentHover })
						tween(edge, EASE.quick, { Transparency = 0.45, Color = UI.theme.accent })
					end)
					b.MouseLeave:Connect(function()
						tween(b, EASE.quick, { TextColor3 = UI.theme.accent })
						tween(edge, EASE.quick, { Transparency = 0.88, Color = UI.theme.text })
					end)
					b.MouseButton1Click:Connect(function()
						bScale.Scale = 0.82
						tween(bScale, EASE.snap, { Scale = 1 })
						onStep(delta)
						refresh()
					end)
				end
				stepButton("−", -106, -1)
				stepButton("+", -22, 1)

				return refresh
			end

			function cardObject:Slider(text, min, max, initial, callback, hint)
				local holder, anchor = row(text, hint)
				local value = math.clamp(initial or min, min, max)

				local readout = Instance.new("TextLabel")
				readout.Size = UDim2.fromOffset(40, 22)
				readout.Position = place(-40, anchor, 22)
				readout.BackgroundColor3 = UI.theme.input
				readout.BorderSizePixel = 0
				readout.Text = tostring(math.floor(value))
				readout.TextColor3 = UI.theme.accentSoft
				readout.Font = UI.font.mono
				readout.TextSize = 11
				readout.Parent = holder
				corner(readout, 7)
				stroke(readout, 0.88)

				local track = Instance.new("TextButton")
				track.Size = UDim2.fromOffset(68, 5)
				track.Position = place(-116, anchor, 5)
				track.BackgroundColor3 = UI.theme.input
				track.BorderSizePixel = 0
				track.Text = ""
				track.AutoButtonColor = false
				track.Parent = holder
				corner(track, 3)

				local alpha0 = (value - min) / math.max(max - min, 1)
				local fill = Instance.new("Frame")
				fill.Size = UDim2.fromScale(alpha0, 1)
				fill.BackgroundColor3 = UI.theme.accent
				fill.BorderSizePixel = 0
				fill.Parent = track
				corner(fill, 3)
				accentGradient(fill)

				local knob = Instance.new("Frame")
				knob.Size = UDim2.fromOffset(12, 12)
				knob.Position = UDim2.new(alpha0, 0, 0.5, 0)
				knob.AnchorPoint = Vector2.new(0.5, 0.5)
				knob.BackgroundColor3 = UI.theme.accentHover
				knob.BorderSizePixel = 0
				knob.Parent = track
				corner(knob, 6)
				local knobScale = Instance.new("UIScale")
				knobScale.Parent = knob

				local dragging = false
				local function setFromX(x)
					local alpha = math.clamp(
						(x - track.AbsolutePosition.X) / math.max(track.AbsoluteSize.X, 1), 0, 1)
					value = min + alpha * (max - min)
					fill.Size = UDim2.fromScale(alpha, 1)
					knob.Position = UDim2.new(alpha, 0, 0.5, 0)
					readout.Text = tostring(math.floor(value))
					if callback then callback(value) end
				end

				track.MouseButton1Down:Connect(function(x)
					dragging = true
					tween(knobScale, EASE.snap, { Scale = 1.35 })
					setFromX(x)
				end)
				UserInputService.InputEnded:Connect(function(input)
					if input.UserInputType == Enum.UserInputType.MouseButton1 and dragging then
						dragging = false
						tween(knobScale, EASE.snap, { Scale = 1 })
					end
				end)
				UserInputService.InputChanged:Connect(function(input)
					if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
						setFromX(input.Position.X)
					end
				end)

				return { get = function() return value end }
			end

			function cardObject:Dropdown(text, choices, initial, callback, hint)
				local holder, anchor = row(text, hint)
				holder.ZIndex = 2
				local current = initial or choices[1]
				local open = false

				local box = Instance.new("TextButton")
				box.Size = UDim2.fromOffset(108, 24)
				box.Position = place(-108, anchor, 24)
				box.BackgroundColor3 = UI.theme.input
				box.BorderSizePixel = 0
				box.Text = ""
				box.AutoButtonColor = false
				box.Parent = holder
				corner(box, 8)
				local boxEdge = stroke(box, 0.88)

				local boxText = label(box, tostring(current), 11, UI.font.body,
					UI.theme.accentSoft)
				boxText.Size = UDim2.new(1, -26, 1, 0)
				boxText.Position = UDim2.new(0, 10, 0, 0)
				boxText.TextTruncate = Enum.TextTruncate.AtEnd

				local arrow = label(box, "▾", 11, UI.font.body, UI.theme.accent)
				arrow.Size = UDim2.fromOffset(16, 24)
				arrow.Position = UDim2.new(1, -20, 0, 0)
				arrow.TextXAlignment = Enum.TextXAlignment.Center

				local list = Instance.new("Frame")
				list.Size = UDim2.new(0, 108, 0, 0)
				list.AutomaticSize = Enum.AutomaticSize.Y
				list.Position = anchor and UDim2.new(1, -108, 0, anchor + 15)
					or UDim2.new(1, -108, 0.5, 15)
				list.BackgroundColor3 = UI.theme.input
				list.BorderSizePixel = 0
				list.Visible = false
				list.ZIndex = 20
				list.Parent = holder
				corner(list, 8)
				stroke(list, 0.72, UI.theme.accent)
				local listScale = Instance.new("UIScale")
				listScale.Scale = 0.9
				listScale.Parent = list
				local listPad = Instance.new("UIPadding")
				listPad.PaddingTop = UDim.new(0, 4)
				listPad.PaddingBottom = UDim.new(0, 4)
				listPad.Parent = list
				local listLayout = Instance.new("UIListLayout")
				listLayout.Parent = list

				for _, choice in ipairs(choices) do
					local option = Instance.new("TextButton")
					option.Size = UDim2.new(1, 0, 0, 24)
					option.BackgroundColor3 = UI.theme.accent
					option.BackgroundTransparency = 1
					option.Text = tostring(choice)
					option.TextColor3 = UI.theme.text
					option.TextTransparency = UI.theme.dimAlpha
					option.Font = UI.font.body
					option.TextSize = 11
					option.ZIndex = 21
					option.AutoButtonColor = false
					option.Parent = list
					option.MouseEnter:Connect(function()
						tween(option, EASE.quick,
							{ TextTransparency = 0, BackgroundTransparency = 0.9 })
					end)
					option.MouseLeave:Connect(function()
						tween(option, EASE.quick,
							{ TextTransparency = UI.theme.dimAlpha, BackgroundTransparency = 1 })
					end)
					option.MouseButton1Click:Connect(function()
						current = choice
						boxText.Text = tostring(choice)
						open = false
						arrow.Rotation = 0
						list.Visible = false
						if callback then callback(choice) end
					end)
				end

				box.MouseButton1Click:Connect(function()
					open = not open
					tween(arrow, EASE.soft, { Rotation = open and 180 or 0 })
					tween(boxEdge, EASE.quick, {
						Transparency = open and 0.45 or 0.88,
						Color = open and UI.theme.accent or UI.theme.text,
					})
					if open then
						list.Visible = true
						listScale.Scale = 0.9
						tween(listScale, EASE.snap, { Scale = 1 })
					else
						local t = tween(listScale, EASE.quick, { Scale = 0.9 })
						t.Completed:Connect(function()
							if not open then list.Visible = false end
						end)
					end
				end)

				return {
					get = function() return current end,
					set = function(_, v) current = v boxText.Text = tostring(v) end,
				}
			end

			function cardObject:Button(text, callback, tone)
				cardObject.rows += 1
				local shade = tone or UI.theme.accent
				local button = Instance.new("TextButton")
				button.Size = UDim2.new(1, 0, 0, 30)
				button.BackgroundColor3 = shade
				button.BackgroundTransparency = 0.87
				button.BorderSizePixel = 0
				button.Text = string.upper(text)
				button.TextColor3 = shade
				button.Font = UI.font.heading
				button.TextSize = 11
				button.AutoButtonColor = false
				button.LayoutOrder = cardObject.rows
				button.Parent = body
				corner(button, 9)
				local edge = stroke(button, 0.68, shade)
				local bScale = Instance.new("UIScale")
				bScale.Parent = button

				-- The press flash is a sibling frame rather than a colour tween on
				-- the button itself: tweening the fill fights the hover tween and
				-- the two end up cancelling each other mid-click.
				local flash = Instance.new("Frame")
				flash.Size = UDim2.fromScale(1, 1)
				flash.BackgroundColor3 = shade
				flash.BackgroundTransparency = 1
				flash.BorderSizePixel = 0
				flash.ZIndex = 0
				flash.Parent = button
				corner(flash, 9)

				button.MouseEnter:Connect(function()
					tween(button, EASE.quick, { BackgroundTransparency = 0.74 })
					tween(edge, EASE.quick, { Transparency = 0.4 })
				end)
				button.MouseLeave:Connect(function()
					tween(button, EASE.soft, { BackgroundTransparency = 0.87 })
					tween(edge, EASE.soft, { Transparency = 0.68 })
				end)
				button.MouseButton1Click:Connect(function()
					bScale.Scale = 0.97
					tween(bScale, EASE.snap, { Scale = 1 })
					flash.BackgroundTransparency = 0.45
					tween(flash, EASE.slow, { BackgroundTransparency = 1 })
					if callback then task.spawn(callback) end
				end)

				register(button, text)
				return button
			end

			-- A single line of text the caller updates itself.
			function cardObject:Label(initial, tone)
				cardObject.rows += 1
				local l = label(body, initial or "", 12, UI.font.body,
					tone or UI.theme.text, tone and 0 or UI.theme.dimAlpha)
				l.Size = UDim2.new(1, 0, 0, 18)
				l.LayoutOrder = cardObject.rows
				l.TextTruncate = Enum.TextTruncate.AtEnd
				return { set = function(_, text) l.Text = text end, instance = l }
			end

			-- A monospace read-out block for live numbers and log lines. Lines
			-- written in ALL CAPS are rendered as accent headings.
			function cardObject:Readout(lineCount, colorFor)
				local lines = {}
				for i = 1, (lineCount or 8) do
					cardObject.rows += 1
					local l = label(body, "", 11, UI.font.mono,
						UI.theme.text, UI.theme.dimAlpha)
					l.Size = UDim2.new(1, 0, 0, 15)
					l.LayoutOrder = cardObject.rows
					l.TextTruncate = Enum.TextTruncate.AtEnd
					lines[i] = l
				end
				return {
					set = function(_, entries)
						for i, l in ipairs(lines) do
							local text = entries[i] or ""
							l.Text = text
							local custom = colorFor and colorFor(text)
							if custom then
								l.TextColor3 = custom
								l.TextTransparency = 0
							elseif text ~= "" and text:match("^[%u][%u%d %-%+/]*$") then
								l.TextColor3 = UI.theme.accent
								l.TextTransparency = 0
							else
								l.TextColor3 = UI.theme.accentSoft
								l.TextTransparency = 0.42
							end
						end
					end,
					lines = lines,
				}
			end

			return cardObject
		end

		table.insert(self.pages, pageObject)
		if #self.pages == 1 then select() end
		return pageObject
	end

	return window
end

return UI
