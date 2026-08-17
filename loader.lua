--!nocheck
-- sel01 hub loader - by seltonmt
--
-- One line in the executor, every game after that is automatic:
--
--   loadstring(game:HttpGet("https://raw.githubusercontent.com/seltonmt012/sel01-rbx/main/loader.lua"))()
--
-- What it does, in order:
--
--   1. reads index.json from the repo (the registry of every game script)
--   2. matches the current place by PlaceId, and if that misses, by running the
--      entry's `detect` snippet - place ids change per map/lobby, capabilities
--      do not (Clean all the leaves teleports into a second place mid-run)
--   3. fetches lib/ui-template.lua ONCE, keeps the loaded module in _G.__SEL.ui
--      and also writefile()s it into the executor workspace, so a game script
--      that still does loadstring(readfile("ui-template.lua")) keeps working
--   4. runs the matching game script
--   5. re-arms itself with queue_on_teleport, so a lobby -> map teleport does
--      not drop the automation
--
-- Everything it downloads is cached under the executor workspace in sel01/, and
-- a failed HttpGet falls back to that cache instead of leaving you with nothing.
--
-- Nothing matched? A small panel lists every game in the registry and lets you
-- force one, and _G.__SEL.load("lootevo") does the same from the console.

local BASE = "https://raw.githubusercontent.com/seltonmt012/sel01-rbx/main/"
local CACHE = "sel01/"

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local StarterGui = game:GetService("StarterGui")

if not game:IsLoaded() then game.Loaded:Wait() end

-- Re-executing does not restart the Lua VM, so a previous run's panels and loops
-- are still alive. Bump the generation and let the old ones notice.
local PREV = _G.__SEL
local GEN = ((PREV and PREV.gen) or 0) + 1

-- Executor globals differ per executor; every optional one degrades to a no-op.
local writefile   = writefile or function() end
local readfile    = readfile
local isfile      = isfile or function() return false end
local isfolder    = isfolder or function() return true end
local makefolder  = makefolder or function() end
local queueTp     = queue_on_teleport or queueonteleport
    or (syn and syn.queue_on_teleport) or (fluxus and fluxus.queue_on_teleport)

local function notify(text, duration)
    print("[sel01] " .. text)
    pcall(function()
        StarterGui:SetCore("SendNotification", {
            Title = "sel01", Text = text, Duration = duration or 4,
        })
    end)
end

local function httpGet(url)
    local ok, body = pcall(function() return game:HttpGet(url, true) end)
    if ok and type(body) == "string" and #body > 0 then return body end
    -- Some executors only expose the request form.
    local req = (syn and syn.request) or (http and http.request) or http_request or request
    if req then
        local ok2, res = pcall(req, { Url = url, Method = "GET" })
        if ok2 and type(res) == "table" and res.StatusCode == 200 then return res.Body end
    end
    return nil
end

-- Downloads path from the repo and caches it. raw.githubusercontent serves a
-- cached copy for a few minutes, so the timestamp is what makes an edit show up
-- in game without waiting.
local function fetch(path)
    if not isfolder(CACHE) then makefolder(CACHE) end
    local cached = CACHE .. path:gsub("/", "_")
    local body = httpGet(BASE .. path .. "?t=" .. tostring(os.time()))
    if body then
        pcall(writefile, cached, body)
        return body, "net"
    end
    if isfile(cached) and readfile then
        local ok, disk = pcall(readfile, cached)
        if ok and disk and #disk > 0 then return disk, "cache" end
    end
    return nil
end

local function run(source, chunkName)
    local chunk, err = loadstring(source, "@" .. chunkName)
    if not chunk then return nil, err end
    return chunk
end

-- Armed before anything else can fail. A lobby with no connection still
-- teleports into the map, and the map is where the run happens - dropping the
-- re-arm because index.json was unreachable would lose the whole session.
if queueTp then
    pcall(queueTp, 'loadstring(game:HttpGet("' .. BASE .. 'loader.lua"))()')
end

--------------------------------------------------------------------------------
-- registry
--------------------------------------------------------------------------------

local indexBody, indexFrom = fetch("index.json")
if not indexBody then
    notify("index.json unreachable and no cache - nothing loaded", 8)
    return
end

local okIndex, INDEX = pcall(function() return HttpService:JSONDecode(indexBody) end)
if not okIndex or type(INDEX) ~= "table" or type(INDEX.games) ~= "table" then
    notify("index.json is not valid JSON", 8)
    return
end

--------------------------------------------------------------------------------
-- shared UI
--------------------------------------------------------------------------------

-- Loaded once per session and handed to every game script through _G.__SEL.ui,
-- so five scripts in one session do not fetch and build the same module five
-- times. The workspace copy exists for scripts run by hand through the bridge,
-- which have no hub around them.
local UI
local function ui()
    if UI then return UI end
    local path = INDEX.ui or "lib/ui-template.lua"
    local body = fetch(path)
    if not body then return nil end
    pcall(writefile, "ui-template.lua", body)
    local chunk = run(body, path)
    if not chunk then return nil end
    local ok, module = pcall(chunk)
    if ok and type(module) == "table" then UI = module end
    return UI
end

--------------------------------------------------------------------------------
-- matching
--------------------------------------------------------------------------------

local function matchesPlace(entry)
    if type(entry.places) ~= "table" then return false end
    for _, id in ipairs(entry.places) do
        if tonumber(id) == game.PlaceId then return true end
    end
    return false
end

-- `detect` is a Lua snippet in the registry that returns a boolean. It is what
-- catches a place id we have never seen: a map place, a private server copy or
-- a renamed sister place all still expose the same modules and remotes.
local function matchesDetect(entry)
    if type(entry.detect) ~= "string" or entry.detect == "" then return false end
    local chunk = run("return function() " .. entry.detect .. " end", "detect:" .. tostring(entry.alias))
    if not chunk then return false end
    local okOuter, fn = pcall(chunk)
    if not okOuter or type(fn) ~= "function" then return false end
    local ok, result = pcall(fn)
    return ok and result == true
end

local function pick()
    for _, entry in ipairs(INDEX.games) do
        if matchesPlace(entry) then return entry, "place" end
    end
    for _, entry in ipairs(INDEX.games) do
        if matchesDetect(entry) then return entry, "detect" end
    end
    return nil
end

local function byAlias(alias)
    alias = tostring(alias):lower()
    for _, entry in ipairs(INDEX.games) do
        if tostring(entry.alias):lower() == alias then return entry end
    end
    for _, entry in ipairs(INDEX.games) do
        if tostring(entry.name):lower():find(alias, 1, true) then return entry end
    end
    return nil
end

--------------------------------------------------------------------------------
-- loading a game script
--------------------------------------------------------------------------------

local function loadGame(entry, why)
    if type(entry) == "string" then
        local found = byAlias(entry)
        if not found then
            notify("no game called '" .. entry .. "' in the registry", 6)
            return false
        end
        entry = found
    end
    if not entry then return false end

    local body, from = fetch(entry.file)
    if not body then
        notify("could not fetch " .. tostring(entry.file), 8)
        return false
    end

    ui()  -- the script expects _G.__SEL.ui to be there before it runs
    _G.__SEL.game = entry
    _G.__SEL.source = from

    local chunk, err = run(body, entry.file)
    if not chunk then
        notify("syntax error in " .. entry.file .. ": " .. tostring(err), 10)
        warn("[sel01] " .. tostring(err))
        return false
    end

    notify((entry.name or entry.alias) .. "  (" .. (why or "manual") .. ", " .. from .. ")")
    local ok, runErr = pcall(chunk)
    if not ok then
        notify("crashed: " .. tostring(runErr), 10)
        warn("[sel01] " .. tostring(runErr))
        return false
    end
    return true
end

--------------------------------------------------------------------------------
-- fallback picker
--------------------------------------------------------------------------------

-- Only built when nothing matched. It is the same panel every game script uses,
-- so there is exactly one look in the whole hub.
local function textPicker()
    notify("no script for place " .. game.PlaceId .. " - pick one manually", 10)
    print("[sel01] _G.__SEL.load(\"alias\"):")
    for _, entry in ipairs(INDEX.games) do
        print(string.format("  %-14s %s", entry.alias or "?", entry.name or ""))
    end
end

local function buildPicker()
    local U = ui()
    if not U or type(U.Window) ~= "function" then return false end
    if _G.__SEL.pickerWindow then pcall(function() _G.__SEL.pickerWindow:Destroy() end) end

    local win = U.Window({
        title = "SEL", accentTitle = "01", subtitle = "seltonmt",
        badge = "☰", width = 760, height = 520,
    })
    local page = win:Page("HUB", U.icon and U.icon.list or nil)
    local info = page:Card("PLACE", 1)
    info:Label("place " .. tostring(game.PlaceId))
    info:Label("no script registered for this game")
    info:Button("Re-check", function()
        local entry, why = pick()
        if entry then win:Destroy() loadGame(entry, why) end
    end)

    local list = page:Card("SCRIPTS", 2)
    for _, entry in ipairs(INDEX.games) do
        local tone = entry.status == "wip" and U.theme.warn or nil
        list:Button(entry.name or entry.alias, function()
            win:Destroy()
            _G.__SEL.pickerWindow = nil
            loadGame(entry, "forced")
        end, tone)
    end
    win:SetStatus("place " .. tostring(game.PlaceId) .. "   " .. #INDEX.games .. " scripts")
    win:Refresh()
    _G.__SEL.pickerWindow = win
    return true
end

-- The panel is a convenience, not a dependency: if the template cannot be
-- fetched or built, the list still has to reach the console, otherwise an
-- unknown place looks exactly like a loader that silently did nothing.
local function picker()
    local ok, built = pcall(buildPicker)
    if not ok or not built then textPicker() end
    if not ok then warn("[sel01] picker: " .. tostring(built)) end
end

--------------------------------------------------------------------------------
-- public handle
--------------------------------------------------------------------------------

_G.__SEL = {
    gen = GEN,
    base = BASE,
    index = INDEX,
    hubVersion = INDEX.version,
    indexFrom = indexFrom,
    ui = nil,          -- filled by ui() on first use
    game = nil,
    fetch = fetch,
    load = function(alias) return loadGame(alias, "manual") end,
    list = function()
        local out = {}
        for _, entry in ipairs(INDEX.games) do
            out[#out + 1] = string.format("%-14s %s", entry.alias or "?", entry.name or "")
        end
        return table.concat(out, "\n")
    end,
    reload = function()
        local src = httpGet(BASE .. "loader.lua?t=" .. tostring(os.time()))
        if src then local c = run(src, "loader.lua") if c then return c() end end
        notify("reload failed", 6)
    end,
    picker = picker,
}
setmetatable(_G.__SEL, { __index = function(t, k)
    if k == "ui" then return ui() end
    return nil
end })

--------------------------------------------------------------------------------

local entry, why = pick()
if entry then
    loadGame(entry, why)
else
    picker()
end
