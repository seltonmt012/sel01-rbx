--!nocheck
-- ui-template.lua  --  the house UI for every script in this folder  --  seltonmt
--
-- Ported from "UI Layout im Bloodline-Stil" (the Neverlose-style mock the user
-- supplied). Use this for EVERY panel from now on - do not invent a new look
-- per game.
--
--   local UI = loadstring(readfile("ui-template.lua"))()
--   local win  = UI.Window({ title = "SELL", accentTitle = "ORES", subtitle = "seltonmt" })
--   local page = win:Page("FARMING", UI.icon.sliders)
--   local card = page:Card("ORE", 1)      -- 1 = left, 2 = right, 0 = full width
--   card:Toggle("Buy rolled ore", CONFIG.autoBuyOre, function(v) CONFIG.autoBuyOre = v end, "hint")
--   local refresh = card:Stepper("Max payback", getText, onStep)   -- returns a refresher
--   card:Slider("Rate", 2, 40, 12, function(v) ... end)
--   card:Dropdown("Mode", { "Fast", "Safe" }, "Fast", function(v) ... end)
--   card:Button("Unstuck", function() ... end, UI.theme.bad)
--   local out = card:Readout(12); out:set({ "STATUS", "  income 47.3K/s" })
--   win:SetStatus("213K wins   12B dmg   stage 7")       -- the live header line
--
-- Layout, straight from the mock: a 78px icon rail, a 224px nav column holding
-- the search box and the grouped entries, then the content area with a header, a
-- chip bar listing every enabled toggle, and a two-column card grid.
--
-- Implementation notes worth keeping:
--   * The card grid is NOT a UIGridLayout. A grid forces every cell to one size,
--     which fights AutomaticSize and clipped every card to a fixed height. Two
--     plain columns, each with its own UIListLayout, let cards size themselves.
--   * Chips are keyed by an internal counter, not by their caption, so two
--     toggles that happen to share a label do not overwrite each other.
--   * Search hides rows and then hides any card that has no visible row left,
--     and dims the nav entry of a page with no hits.

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local plr = Players.LocalPlayer

local UI = {}

-- Palette, taken from the mock's hex values ------------------------------------
UI.theme = {
	rail = Color3.fromHex("0b0e13"),
	sidebar = Color3.fromHex("0f131a"),
	window = Color3.fromHex("12161d"),
	header = Color3.fromHex("10151c"),
	subBar = Color3.fromHex("0f141b"),
	card = Color3.fromHex("151a22"),
	input = Color3.fromHex("12171f"),
	backdrop = Color3.fromHex("0c0f14"),

	accent = Color3.fromHex("2aa3f0"),
	accentHover = Color3.fromHex("6cc2f7"),
	accentSoft = Color3.fromHex("9ed6f9"),

	-- tones that carry meaning; the mock is monochrome but the panels are not
	good = Color3.fromRGB(86, 208, 140),
	warn = Color3.fromRGB(244, 176, 92),
	bad = Color3.fromRGB(232, 104, 104),

	text = Color3.fromRGB(255, 255, 255),

	-- The mock leans on rgba() a lot; in Roblox that is a solid colour plus a
	-- transparency, so the alphas live here rather than being guessed per call.
	lineAlpha = 0.93,     -- rgba(255,255,255,0.07)
	dimAlpha = 0.55,      -- rgba(255,255,255,0.45)
	fainterAlpha = 0.72,  -- rgba(255,255,255,0.28)
}

UI.font = {
	heading = Enum.Font.GothamBold,   -- stands in for Oxanium
	body = Enum.Font.Gotham,          -- stands in for Rajdhani
	mono = Enum.Font.Code,
}

-- Icon glyphs for the 78px rail. Roblox has no inline SVG, so the mock's icons
-- become single characters.
UI.icon = {
	sliders = "≡", eye = "◉", target = "◎", shield = "◇",
	bolt = "⚡", gear = "⚙", list = "▤", chart = "▦",
	sword = "†", coin = "◍", flask = "◊", map = "◈",
	pickaxe = "⛏", bag = "▣", clock = "◷", flame = "✦",
}

local function corner(instance, radius)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius or 7)
	c.Parent = instance
	return c
end

local function stroke(instance, alpha, color)
	local s = Instance.new("UIStroke")
	s.Color = color or UI.theme.text
	s.Transparency = alpha or UI.theme.lineAlpha
	s.Parent = instance
	return s
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
	corner(root, 14)
	stroke(root)

	local window = {
		gui = gui, root = root,
		pages = {}, chips = {}, searchable = {}, cards = {},
		chipCount = 0,
	}

	-- Icon rail ----------------------------------------------------------------
	local rail = Instance.new("Frame")
	rail.Size = UDim2.new(0, 78, 1, 0)
	rail.BackgroundColor3 = UI.theme.rail
	rail.BorderSizePixel = 0
	rail.Parent = root
	corner(rail, 14)

	local railFill = Instance.new("Frame")   -- squares off the right-hand corners
	railFill.Size = UDim2.new(0, 14, 1, 0)
	railFill.Position = UDim2.new(1, -14, 0, 0)
	railFill.BackgroundColor3 = UI.theme.rail
	railFill.BorderSizePixel = 0
	railFill.Parent = rail

	local railList = Instance.new("UIListLayout")
	railList.Padding = UDim.new(0, 4)
	railList.HorizontalAlignment = Enum.HorizontalAlignment.Center
	railList.SortOrder = Enum.SortOrder.LayoutOrder
	railList.Parent = rail

	local railPad = Instance.new("UIPadding")
	railPad.PaddingTop = UDim.new(0, 16)
	railPad.Parent = rail

	local badge = Instance.new("Frame")
	badge.Size = UDim2.fromOffset(32, 32)
	badge.BackgroundColor3 = UI.theme.accent
	badge.BackgroundTransparency = 0.84
	badge.BorderSizePixel = 0
	badge.LayoutOrder = 0
	badge.Parent = rail
	corner(badge, 9)
	stroke(badge, 0.6, UI.theme.accent)
	local badgeText = label(badge, options.badge or "◈", 15, UI.font.heading, UI.theme.accent)
	badgeText.Size = UDim2.fromScale(1, 1)
	badgeText.TextXAlignment = Enum.TextXAlignment.Center

	-- Sidebar ------------------------------------------------------------------
	local sidebar = Instance.new("Frame")
	sidebar.Size = UDim2.new(0, 224, 1, 0)
	sidebar.Position = UDim2.new(0, 78, 0, 0)
	sidebar.BackgroundColor3 = UI.theme.sidebar
	sidebar.BorderSizePixel = 0
	sidebar.Parent = root

	local brand = label(sidebar, "", 20, UI.font.heading)
	brand.Size = UDim2.new(1, -36, 0, 24)
	brand.Position = UDim2.new(0, 18, 0, 20)
	brand.RichText = true
	brand.Text = string.format('%s<font color="#2aa3f0">%s</font>',
		options.title or "PANEL", options.accentTitle or "")

	local searchWrap = Instance.new("Frame")
	searchWrap.Size = UDim2.new(1, -28, 0, 32)
	searchWrap.Position = UDim2.new(0, 14, 0, 52)
	searchWrap.BackgroundColor3 = UI.theme.input
	searchWrap.BorderSizePixel = 0
	searchWrap.Parent = sidebar
	corner(searchWrap, 8)
	stroke(searchWrap, 0.92)

	local search = Instance.new("TextBox")
	search.Size = UDim2.new(1, -34, 1, 0)
	search.Position = UDim2.new(0, 10, 0, 0)
	search.BackgroundTransparency = 1
	search.PlaceholderText = "Einstellung suchen…"
	search.Text = ""
	search.TextXAlignment = Enum.TextXAlignment.Left
	search.TextColor3 = UI.theme.text
	search.PlaceholderColor3 = UI.theme.text
	search.Font = UI.font.body
	search.TextSize = 13
	search.ClearTextOnFocus = false
	search.Parent = searchWrap
	window.search = search

	local searchClear = Instance.new("TextButton")
	searchClear.Size = UDim2.fromOffset(22, 22)
	searchClear.Position = UDim2.new(1, -26, 0.5, -11)
	searchClear.BackgroundTransparency = 1
	searchClear.Text = "×"
	searchClear.TextColor3 = UI.theme.text
	searchClear.TextTransparency = UI.theme.dimAlpha
	searchClear.Font = UI.font.heading
	searchClear.TextSize = 15
	searchClear.Parent = searchWrap
	searchClear.MouseButton1Click:Connect(function()
		search.Text = ""
		search:ReleaseFocus()
	end)

	local navScroll = Instance.new("ScrollingFrame")
	navScroll.Size = UDim2.new(1, -24, 1, -160)
	navScroll.Position = UDim2.new(0, 12, 0, 94)
	navScroll.BackgroundTransparency = 1
	navScroll.BorderSizePixel = 0
	navScroll.ScrollBarThickness = 3
	navScroll.ScrollBarImageColor3 = UI.theme.accent
	navScroll.ScrollBarImageTransparency = 0.65
	navScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	navScroll.CanvasSize = UDim2.new()
	navScroll.Parent = sidebar

	local navList = Instance.new("UIListLayout")
	navList.Padding = UDim.new(0, 3)
	navList.SortOrder = Enum.SortOrder.LayoutOrder
	navList.Parent = navScroll

	local footer = Instance.new("Frame")
	footer.Size = UDim2.new(1, 0, 0, 58)
	footer.Position = UDim2.new(0, 0, 1, -58)
	footer.BackgroundTransparency = 1
	footer.Parent = sidebar
	local footLine = Instance.new("Frame")
	footLine.Size = UDim2.new(1, 0, 0, 1)
	footLine.BackgroundColor3 = UI.theme.text
	footLine.BackgroundTransparency = UI.theme.lineAlpha
	footLine.BorderSizePixel = 0
	footLine.Parent = footer

	local avatar = Instance.new("Frame")
	avatar.Size = UDim2.fromOffset(34, 34)
	avatar.Position = UDim2.new(0, 18, 0, 12)
	avatar.BackgroundColor3 = UI.theme.text
	avatar.BackgroundTransparency = 0.94
	avatar.BorderSizePixel = 0
	avatar.Parent = footer
	corner(avatar, 17)
	stroke(avatar, 0.65, UI.theme.accent)
	local avatarText = label(avatar, string.sub(plr.Name, 1, 1):upper(), 14,
		UI.font.heading, UI.theme.accent)
	avatarText.Size = UDim2.fromScale(1, 1)
	avatarText.TextXAlignment = Enum.TextXAlignment.Center

	local userName = label(footer, plr.Name, 14, UI.font.body)
	userName.Size = UDim2.new(1, -70, 0, 16)
	userName.Position = UDim2.new(0, 62, 0, 13)
	userName.TextTruncate = Enum.TextTruncate.AtEnd
	local userSub = label(footer, options.subtitle or "seltonmt", 12,
		UI.font.body, UI.theme.text, UI.theme.dimAlpha)
	userSub.Size = UDim2.new(1, -70, 0, 14)
	userSub.Position = UDim2.new(0, 62, 0, 30)

	-- Content ------------------------------------------------------------------
	local content = Instance.new("Frame")
	content.Size = UDim2.new(1, -302, 1, 0)
	content.Position = UDim2.new(0, 302, 0, 0)
	content.BackgroundTransparency = 1
	content.Parent = root

	local head = Instance.new("Frame")
	head.Size = UDim2.new(1, 0, 0, 62)
	head.BackgroundColor3 = UI.theme.header
	head.BorderSizePixel = 0
	head.Parent = content

	local headTitle = label(head, options.title or "PANEL", 18, UI.font.heading)
	headTitle.Size = UDim2.new(1, -80, 0, 21)
	headTitle.Position = UDim2.new(0, 26, 0, 11)
	window.headTitle = headTitle

	-- The live line. Kept in the header on purpose: it stays readable while the
	-- window is collapsed, which is the whole point of collapsing it.
	local headSub = label(head, options.subtitle or "", 12, UI.font.mono,
		UI.theme.text, UI.theme.dimAlpha)
	headSub.Size = UDim2.new(1, -80, 0, 15)
	headSub.Position = UDim2.new(0, 26, 0, 33)
	headSub.TextTruncate = Enum.TextTruncate.AtEnd
	window.headSub = headSub

	local collapseButton = Instance.new("TextButton")
	collapseButton.Size = UDim2.fromOffset(26, 22)
	collapseButton.Position = UDim2.new(1, -40, 0, 12)
	collapseButton.BackgroundColor3 = UI.theme.input
	collapseButton.BorderSizePixel = 0
	collapseButton.Text = "–"
	collapseButton.TextColor3 = UI.theme.text
	collapseButton.TextTransparency = UI.theme.dimAlpha
	collapseButton.Font = UI.font.heading
	collapseButton.TextSize = 14
	collapseButton.AutoButtonColor = false
	collapseButton.Parent = head
	corner(collapseButton, 6)
	stroke(collapseButton, 0.9)

	-- Chip bar -----------------------------------------------------------------
	local chipBar = Instance.new("Frame")
	chipBar.Size = UDim2.new(1, 0, 0, 34)
	chipBar.Position = UDim2.new(0, 0, 0, 62)
	chipBar.BackgroundColor3 = UI.theme.subBar
	chipBar.BorderSizePixel = 0
	chipBar.Parent = content

	local chipCaption = label(chipBar, "AKTIV 0", 10, UI.font.heading,
		UI.theme.text, UI.theme.fainterAlpha)
	chipCaption.Size = UDim2.fromOffset(70, 14)
	chipCaption.Position = UDim2.new(0, 26, 0, 10)
	window.chipCaption = chipCaption

	local chipHolder = Instance.new("ScrollingFrame")
	chipHolder.Size = UDim2.new(1, -120, 1, -6)
	chipHolder.Position = UDim2.new(0, 96, 0, 3)
	chipHolder.BackgroundTransparency = 1
	chipHolder.BorderSizePixel = 0
	chipHolder.ScrollBarThickness = 0
	chipHolder.ScrollingDirection = Enum.ScrollingDirection.X
	chipHolder.AutomaticCanvasSize = Enum.AutomaticSize.X
	chipHolder.CanvasSize = UDim2.new()
	chipHolder.Parent = chipBar
	local chipLayout = Instance.new("UIListLayout")
	chipLayout.FillDirection = Enum.FillDirection.Horizontal
	chipLayout.Padding = UDim.new(0, 7)
	chipLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	chipLayout.SortOrder = Enum.SortOrder.LayoutOrder
	chipLayout.Parent = chipHolder
	window.chipHolder = chipHolder

	local pageHolder = Instance.new("Frame")
	pageHolder.Size = UDim2.new(1, 0, 1, -96)
	pageHolder.Position = UDim2.new(0, 0, 0, 96)
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
				(window.activePage == page and 0 or UI.theme.dimAlpha) or 0.8
		end
	end
	search:GetPropertyChangedSignal("Text"):Connect(applyFilter)

	local collapsed = false
	collapseButton.MouseButton1Click:Connect(function()
		collapsed = not collapsed
		collapseButton.Text = collapsed and "+" or "–"
		sidebar.Visible = not collapsed
		rail.Visible = not collapsed
		chipBar.Visible = not collapsed
		pageHolder.Visible = not collapsed
		content.Position = collapsed and UDim2.new() or UDim2.new(0, 302, 0, 0)
		content.Size = collapsed and UDim2.new(1, 0, 1, 0) or UDim2.new(1, -302, 1, 0)
		TweenService:Create(root, TweenInfo.new(0.16, Enum.EasingStyle.Quad), {
			Size = collapsed and UDim2.fromOffset(WIDTH, 62) or UDim2.fromOffset(WIDTH, HEIGHT),
		}):Play()
	end)

	UserInputService.InputBegan:Connect(function(input, typing)
		if typing then return end
		if input.KeyCode == (options.hotkey or Enum.KeyCode.RightShift) then
			root.Visible = not root.Visible
		end
	end)

	function window:Refresh()
		local active = 0
		for _, chip in ipairs(self.chips) do
			local on = chip.get()
			chip.frame.Visible = on
			if on then active += 1 end
		end
		self.chipCaption.Text = "AKTIV " .. active
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
		page.ScrollBarImageTransparency = 0.65
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
		navEntry.Size = UDim2.new(1, -4, 0, 30)
		navEntry.BackgroundColor3 = UI.theme.text
		navEntry.BackgroundTransparency = 1
		navEntry.BorderSizePixel = 0
		navEntry.Text = ""
		navEntry.AutoButtonColor = false
		navEntry.LayoutOrder = #self.pages + 1
		navEntry.Parent = navScroll
		corner(navEntry, 8)

		local glyph = label(navEntry, iconGlyph or UI.icon.sliders, 13,
			UI.font.body, UI.theme.accent)
		glyph.Size = UDim2.fromOffset(18, 30)
		glyph.Position = UDim2.new(0, 10, 0, 0)
		glyph.TextXAlignment = Enum.TextXAlignment.Center

		local navText = label(navEntry, name, 14, UI.font.body,
			UI.theme.text, UI.theme.dimAlpha)
		navText.Size = UDim2.new(1, -40, 1, 0)
		navText.Position = UDim2.new(0, 34, 0, 0)

		local railEntry = Instance.new("TextButton")
		railEntry.Size = UDim2.fromOffset(58, 42)
		railEntry.BackgroundTransparency = 1
		railEntry.Text = ""
		railEntry.AutoButtonColor = false
		railEntry.LayoutOrder = #self.pages + 1
		railEntry.Parent = rail
		local railGlyph = label(railEntry, iconGlyph or UI.icon.sliders, 16,
			UI.font.body, UI.theme.text, UI.theme.dimAlpha)
		railGlyph.Size = UDim2.new(1, 0, 0, 20)
		railGlyph.Position = UDim2.new(0, 0, 0, 2)
		railGlyph.TextXAlignment = Enum.TextXAlignment.Center
		local railText = label(railEntry, string.sub(name, 1, 8), 9,
			UI.font.heading, UI.theme.text, UI.theme.fainterAlpha)
		railText.Size = UDim2.new(1, 0, 0, 12)
		railText.Position = UDim2.new(0, 0, 0, 24)
		railText.TextXAlignment = Enum.TextXAlignment.Center

		local pageObject = {
			frame = page, name = name, cards = {}, window = self,
			navEntry = navEntry, navText = navText, railGlyph = railGlyph,
			columns = columns, nextColumn = 1,
		}

		local function select()
			for _, other in ipairs(self.pages) do
				other.frame.Visible = false
				other.navEntry.BackgroundTransparency = 1
				other.navText.TextTransparency = UI.theme.dimAlpha
				other.railGlyph.TextTransparency = UI.theme.dimAlpha
			end
			page.Visible = true
			navEntry.BackgroundTransparency = 0.95
			navText.TextTransparency = 0
			railGlyph.TextTransparency = 0
			self.activePage = pageObject
			self.headTitle.Text = name
		end
		pageObject.select = select

		navEntry.MouseButton1Click:Connect(select)
		railEntry.MouseButton1Click:Connect(select)
		navEntry.MouseEnter:Connect(function()
			if self.activePage ~= pageObject then navEntry.BackgroundTransparency = 0.96 end
		end)
		navEntry.MouseLeave:Connect(function()
			if self.activePage ~= pageObject then navEntry.BackgroundTransparency = 1 end
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
			corner(card, 9)
			stroke(card)

			local cardList = Instance.new("UIListLayout")
			cardList.SortOrder = Enum.SortOrder.LayoutOrder
			cardList.Parent = card

			local cardHead = Instance.new("Frame")
			cardHead.Size = UDim2.new(1, 0, 0, 36)
			cardHead.BackgroundTransparency = 1
			cardHead.LayoutOrder = 0
			cardHead.Parent = card
			local headLabel = label(cardHead, string.upper(cardTitle), 11, UI.font.heading,
				UI.theme.text, UI.theme.fainterAlpha)
			headLabel.Size = UDim2.new(1, -32, 1, 0)
			headLabel.Position = UDim2.new(0, 16, 0, 0)
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
			pad.PaddingTop = UDim.new(0, 8)
			pad.PaddingBottom = UDim.new(0, 12)
			pad.PaddingLeft = UDim.new(0, 14)
			pad.PaddingRight = UDim.new(0, 14)
			pad.Parent = body

			local cardObject = { frame = card, body = body, rows = 0, entries = {} }
			table.insert(self.cards, cardObject)
			table.insert(window.cards, cardObject)

			local function register(instance, caption)
				local entry = { instance = instance, caption = caption:lower() }
				table.insert(window.searchable, entry)
				table.insert(cardObject.entries, entry)
			end

			-- a row is caption (+ optional hint) on the left, control on the right
			local function row(text, hint, tone)
				cardObject.rows += 1
				local holder = Instance.new("Frame")
				holder.Size = UDim2.new(1, 0, 0, hint and 40 or 30)
				holder.BackgroundTransparency = 1
				holder.LayoutOrder = cardObject.rows
				holder.Parent = body

				local name = label(holder, text, 13, UI.font.body, tone or UI.theme.text)
				name.Size = UDim2.new(1, -116, 0, hint and 18 or 30)
				name.Position = UDim2.new(0, 0, 0, hint and 2 or 0)
				name.TextTruncate = Enum.TextTruncate.AtEnd
				if hint then
					local sub = label(holder, hint, 11, UI.font.body,
						UI.theme.text, UI.theme.fainterAlpha)
					sub.Size = UDim2.new(1, -116, 0, 14)
					sub.Position = UDim2.new(0, 0, 0, 21)
					sub.TextTruncate = Enum.TextTruncate.AtEnd
				end

				register(holder, text)
				return holder
			end

			function cardObject:Toggle(text, initial, callback, hint, tone)
				local holder = row(text, hint, tone)
				local state = initial and true or false

				-- A thin bar on the left doubles as the state indicator, so the
				-- setting reads at a glance without looking at the pill.
				local mark = Instance.new("Frame")
				mark.Size = UDim2.fromOffset(2, 14)
				mark.Position = UDim2.new(0, -8, 0.5, -7)
				mark.BackgroundColor3 = tone or UI.theme.accent
				mark.BackgroundTransparency = state and 0 or 0.85
				mark.BorderSizePixel = 0
				mark.Parent = holder
				corner(mark, 1)

				local pill = Instance.new("TextButton")
				pill.Size = UDim2.fromOffset(36, 19)
				pill.Position = UDim2.new(1, -36, 0.5, -9)
				pill.BackgroundColor3 = state and (tone or UI.theme.accent) or UI.theme.input
				pill.BorderSizePixel = 0
				pill.Text = ""
				pill.AutoButtonColor = false
				pill.Parent = holder
				corner(pill, 10)
				stroke(pill, 0.9)

				local knob = Instance.new("Frame")
				knob.Size = UDim2.fromOffset(13, 13)
				knob.Position = state and UDim2.new(1, -16, 0, 3) or UDim2.new(0, 3, 0, 3)
				knob.BackgroundColor3 = UI.theme.text
				knob.BorderSizePixel = 0
				knob.Parent = pill
				corner(knob, 7)

				-- the chip that appears in the AKTIV bar while this is on
				window.chipCount += 1
				local chip = Instance.new("Frame")
				chip.Size = UDim2.fromOffset(0, 22)
				chip.AutomaticSize = Enum.AutomaticSize.X
				chip.BackgroundColor3 = tone or UI.theme.accent
				chip.BackgroundTransparency = 0.88
				chip.BorderSizePixel = 0
				chip.Visible = state
				chip.LayoutOrder = window.chipCount
				chip.Parent = window.chipHolder
				corner(chip, 11)
				stroke(chip, 0.7, tone or UI.theme.accent)
				local chipText = label(chip, text, 11, UI.font.body,
					tone or UI.theme.accentSoft)
				chipText.Size = UDim2.new(0, 0, 1, 0)
				chipText.AutomaticSize = Enum.AutomaticSize.X
				chipText.Position = UDim2.new(0, 10, 0, 0)
				local chipPad = Instance.new("UIPadding")
				chipPad.PaddingRight = UDim.new(0, 20)
				chipPad.Parent = chip

				table.insert(window.chips, { frame = chip, get = function() return state end })

				local function apply()
					local info = TweenInfo.new(0.15, Enum.EasingStyle.Quad)
					TweenService:Create(pill, info, {
						BackgroundColor3 = state and (tone or UI.theme.accent) or UI.theme.input,
					}):Play()
					TweenService:Create(knob, info, {
						Position = state and UDim2.new(1, -16, 0, 3) or UDim2.new(0, 3, 0, 3),
					}):Play()
					mark.BackgroundTransparency = state and 0 or 0.85
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

			-- The stepper from the old panels: a centred value chip between − and
			-- +. getText is a function so the caller keeps ownership of the value.
			function cardObject:Stepper(text, getText, onStep, hint)
				local holder = row(text, hint)

				local box = Instance.new("Frame")
				box.Size = UDim2.fromOffset(58, 20)
				box.Position = UDim2.new(1, -80, 0.5, -10)
				box.BackgroundColor3 = UI.theme.input
				box.BorderSizePixel = 0
				box.Parent = holder
				corner(box, 5)
				stroke(box, 0.92)

				local value = label(box, tostring(getText()), 11, UI.font.body)
				value.Size = UDim2.new(1, -6, 1, 0)
				value.Position = UDim2.new(0, 3, 0, 0)
				value.TextXAlignment = Enum.TextXAlignment.Center
				value.TextTruncate = Enum.TextTruncate.AtEnd

				local function refresh() value.Text = tostring(getText()) end

				local function stepButton(glyphText, x, delta)
					local b = Instance.new("TextButton")
					b.Size = UDim2.fromOffset(20, 20)
					b.Position = UDim2.new(1, x, 0.5, -10)
					b.BackgroundColor3 = UI.theme.input
					b.BorderSizePixel = 0
					b.Text = glyphText
					b.TextColor3 = UI.theme.accent
					b.Font = UI.font.heading
					b.TextSize = 14
					b.AutoButtonColor = false
					b.Parent = holder
					corner(b, 5)
					stroke(b, 0.92)
					b.MouseEnter:Connect(function() b.TextColor3 = UI.theme.accentHover end)
					b.MouseLeave:Connect(function() b.TextColor3 = UI.theme.accent end)
					b.MouseButton1Click:Connect(function()
						onStep(delta)
						refresh()
					end)
				end
				stepButton("−", -100, -1)
				stepButton("+", -20, 1)

				return refresh
			end

			function cardObject:Slider(text, min, max, initial, callback, hint)
				local holder = row(text, hint)
				local value = math.clamp(initial or min, min, max)

				local readout = Instance.new("TextLabel")
				readout.Size = UDim2.fromOffset(38, 20)
				readout.Position = UDim2.new(1, -38, 0.5, -10)
				readout.BackgroundColor3 = UI.theme.input
				readout.BorderSizePixel = 0
				readout.Text = tostring(math.floor(value))
				readout.TextColor3 = UI.theme.text
				readout.Font = UI.font.body
				readout.TextSize = 11
				readout.Parent = holder
				corner(readout, 5)
				stroke(readout, 0.92)

				local track = Instance.new("TextButton")
				track.Size = UDim2.fromOffset(64, 4)
				track.Position = UDim2.new(1, -108, 0.5, -2)
				track.BackgroundColor3 = UI.theme.input
				track.BorderSizePixel = 0
				track.Text = ""
				track.AutoButtonColor = false
				track.Parent = holder
				corner(track, 2)

				local alpha0 = (value - min) / math.max(max - min, 1)
				local fill = Instance.new("Frame")
				fill.Size = UDim2.fromScale(alpha0, 1)
				fill.BackgroundColor3 = UI.theme.accent
				fill.BorderSizePixel = 0
				fill.Parent = track
				corner(fill, 2)

				local knob = Instance.new("Frame")
				knob.Size = UDim2.fromOffset(11, 11)
				knob.Position = UDim2.new(alpha0, -5, 0.5, -5)
				knob.BackgroundColor3 = UI.theme.accentHover
				knob.BorderSizePixel = 0
				knob.Parent = track
				corner(knob, 6)

				local dragging = false
				local function setFromX(x)
					local alpha = math.clamp(
						(x - track.AbsolutePosition.X) / math.max(track.AbsoluteSize.X, 1), 0, 1)
					value = min + alpha * (max - min)
					fill.Size = UDim2.fromScale(alpha, 1)
					knob.Position = UDim2.new(alpha, -5, 0.5, -5)
					readout.Text = tostring(math.floor(value))
					if callback then callback(value) end
				end

				track.MouseButton1Down:Connect(function(x)
					dragging = true
					setFromX(x)
				end)
				UserInputService.InputEnded:Connect(function(input)
					if input.UserInputType == Enum.UserInputType.MouseButton1 then dragging = false end
				end)
				UserInputService.InputChanged:Connect(function(input)
					if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
						setFromX(input.Position.X)
					end
				end)

				return { get = function() return value end }
			end

			function cardObject:Dropdown(text, choices, initial, callback, hint)
				local holder = row(text, hint)
				holder.ZIndex = 2
				local current = initial or choices[1]
				local open = false

				local box = Instance.new("TextButton")
				box.Size = UDim2.fromOffset(104, 22)
				box.Position = UDim2.new(1, -104, 0.5, -11)
				box.BackgroundColor3 = UI.theme.input
				box.BorderSizePixel = 0
				box.Text = tostring(current) .. "  ▾"
				box.TextColor3 = UI.theme.text
				box.Font = UI.font.body
				box.TextSize = 11
				box.AutoButtonColor = false
				box.Parent = holder
				corner(box, 6)
				stroke(box, 0.9)

				local list = Instance.new("Frame")
				list.Size = UDim2.new(0, 104, 0, 0)
				list.AutomaticSize = Enum.AutomaticSize.Y
				list.Position = UDim2.new(1, -104, 0.5, 13)
				list.BackgroundColor3 = UI.theme.input
				list.BorderSizePixel = 0
				list.Visible = false
				list.ZIndex = 20
				list.Parent = holder
				corner(list, 6)
				stroke(list, 0.85)
				local listLayout = Instance.new("UIListLayout")
				listLayout.Parent = list

				for _, choice in ipairs(choices) do
					local option = Instance.new("TextButton")
					option.Size = UDim2.new(1, 0, 0, 22)
					option.BackgroundTransparency = 1
					option.Text = tostring(choice)
					option.TextColor3 = UI.theme.text
					option.TextTransparency = UI.theme.dimAlpha
					option.Font = UI.font.body
					option.TextSize = 11
					option.ZIndex = 21
					option.Parent = list
					option.MouseEnter:Connect(function() option.TextTransparency = 0 end)
					option.MouseLeave:Connect(function() option.TextTransparency = UI.theme.dimAlpha end)
					option.MouseButton1Click:Connect(function()
						current = choice
						box.Text = tostring(choice) .. "  ▾"
						open = false
						list.Visible = false
						if callback then callback(choice) end
					end)
				end

				box.MouseButton1Click:Connect(function()
					open = not open
					list.Visible = open
				end)

				return {
					get = function() return current end,
					set = function(_, v) current = v box.Text = tostring(v) .. "  ▾" end,
				}
			end

			function cardObject:Button(text, callback, tone)
				cardObject.rows += 1
				local shade = tone or UI.theme.accent
				local button = Instance.new("TextButton")
				button.Size = UDim2.new(1, 0, 0, 28)
				button.BackgroundColor3 = shade
				button.BackgroundTransparency = 0.88
				button.BorderSizePixel = 0
				button.Text = string.upper(text)
				button.TextColor3 = shade
				button.Font = UI.font.heading
				button.TextSize = 11
				button.AutoButtonColor = false
				button.LayoutOrder = cardObject.rows
				button.Parent = body
				corner(button, 7)
				stroke(button, 0.72, shade)

				button.MouseEnter:Connect(function() button.BackgroundTransparency = 0.76 end)
				button.MouseLeave:Connect(function() button.BackgroundTransparency = 0.88 end)
				button.MouseButton1Click:Connect(function()
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
					l.Size = UDim2.new(1, 0, 0, 14)
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
								l.TextColor3 = UI.theme.text
								l.TextTransparency = UI.theme.dimAlpha
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
