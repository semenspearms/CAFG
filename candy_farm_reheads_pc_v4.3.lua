--[[ ==========================================================================
  RE:Heads, Please! [RNG] — Candy Auto-Farm   (PC / SolaraV3)
  build v4.3 «discovery»   ·   🎃 Halloween Edition 🎃

  Script made by Fluttershyᵗᵐ
  Discord: https://discord.gg/vSbPNdTXw4  (клик по подписи в окне)

  ПОЧЕМУ ПРОШЛАЯ ВЕРСИЯ МОЛЧАЛА И НИЧЕГО НЕ ДЕЛАЛА
    1) Remote = ReplicatedStorage:WaitForChild("Candy2026"):WaitForChild("Remote")
       Если такого пути в игре нет — WaitForChild висит ВЕЧНО, и скрипт
       выглядит как «запустился и ничего не делает».
    2) Сбора не было вообще: CollectAll подходил к позиции конфеты и шёл дальше.
       Ни FireServer, ни промпта, ни касания.
    3) local next = waypoints[idx] — затеняет стандартную функцию next.
    4) FireServer("Sync") каждую секунду без необходимости.

  ЧТО ДЕЛАЕТ v4.3
    * ремоут не угадывается, а ИЩЕТСЯ: перебор всех RemoteEvent/RemoteFunction
      в ReplicatedStorage + ранжирование по имени (candy/collect/sync/2026/...);
    * hook на FireServer найденных кандидатов — собери ОДНУ конфету руками,
      и в лог упадёт точный вызов, который делает сама игра;
    * Snapshot разбирается в 4 форматах (массив / словарь / position|Position|
      CFrame|{x,y,z} / вложенные таблицы);
    * по прибытии к конфете скрипт пытается её взять (ремоут-протокол или близость);
    * окно-GUI с логом + буфер обмена + файл отчёта;
    * сжимаемое/разворачиваемое окно (кнопка «–»/«+» в шапке);
    * клик по подписи «Fluttershyᵗᵐ» открывает / копирует Discord-ссылку;
    * unload без «призраков»; повторный Execute безопасен.

  ХОТКЕИ
    F1 — старт / стоп фарма
    F2 — отчёт (ремоуты, перехваченные вызовы, список конфет)
    F3 — режим walk <-> teleport
    F4 — анти-AFK (периодическое «нажатие» клавиши)
    F6 — UNLOAD (снять скрипт полностью)

  ВАЖНО: протокол сбора конфет НЕ подтверждён. v4.3 его выясняет, а не угадывает.
          Пока не прислан лог — сбор идёт по трём вероятным вызовам + близость.
========================================================================== ]]

--// CONFIG //-----------------------------------------------------------------
local CONFIG = {
    -- хоткеи
    ToggleKey = Enum.KeyCode.F1,
    DumpKey   = Enum.KeyCode.F2,
    ModeKey   = Enum.KeyCode.F3,
    AfkKey    = Enum.KeyCode.F4,
    UnloadKey = Enum.KeyCode.F6,

    -- поведение
    Teleport       = true,    -- true = телепорт к цели, false = пешком по Pathfinding
    AutoCollect    = true,    -- пытаться взять конфету по прибытии
    MaxTargetDist  = 1200,    -- дальше этого — игнор (декор на другом острове)
    WalkDistance   = 4,       -- ближе этого считаем «дошли»
    ArriveTimeout  = 8,       -- сколько секунд ждать прибытия
    GiveUpAfter    = 3,      -- столько промахов и объект уходит в чёрный список
    FreshFor       = 30,      -- данные о конфете старше N секунд считаем устаревшими
    MaxTargets     = 400,     -- предохранитель: больше не запоминаем
    SyncInterval   = 3,       -- как часто просить сервер прислать список (сек)
    RequestSync    = true,    -- отправлять SyncCalls на найденный ремоут
    HookFireServer = true,    -- перехватывать исходящие вызовы (ответ на «как собирается»)
    LoadTelemetry  = false,   -- загрузчик телеметрии rscripts.net (для фарма не нужен)

    -- анти-AFK: «нажимаем» случайную клавишу + клик мыши через VirtualUser
    AfkInterval    = 28,      -- сек между «нажатиями»
    AfkKeys        = {        -- клавиши, которые жмём (без WASD/движения!)
        Enum.KeyCode.U, Enum.KeyCode.I, Enum.KeyCode.K, Enum.KeyCode.L,
        Enum.KeyCode.O, Enum.KeyCode.P, Enum.KeyCode.G, Enum.KeyCode.T,
    },

    -- ЧТО отправлять, чтобы попросить список конфет
    SyncCalls = { "Sync", "GetCandy", "RequestSnapshot" },

    -- ЧЕМ пытаться взять конфету (%id% подставится). Прокручивается по попыткам.
    CollectCalls = {
        { "Collect", "%id%" },
        { "Pickup",  "%id%" },
        { "Take",    "%id%" },
    },

    -- имена, которые НЕ трогаем даже если подошли по фильтру
    Ignore = { "shop", "spinningwheel", "enchant", "horseman", "minion",
               "boardmarker", "spray", "carriage", "upgradevisual", "soda" },

    -- Discord-канал автора: клик по «Fluttershyᵗᵐ» в шапке открывает эту ссылку
    DiscordUrl = "https://discord.gg/vSbPNdTXw4",
}

--// TELEMETRY — опционально, по умолчанию ВЫКЛ ---------------
if CONFIG.LoadTelemetry then
    task.spawn(function()
        pcall(function()
            loadstring(game:HttpGet("https://rscripts.net/api/telemetry/v2/client.lua?s=6ac178171666a9c2a3d01fe1"))()
        end)
    end)
end

--// SERVICES //---------------------------------------------------------------
local Players            = game:GetService("Players")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local RunService         = game:GetService("RunService")
local UserInputService   = game:GetService("UserInputService")
local PathfindingService  = game:GetService("PathfindingService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local VirtualUser         = game:GetService("VirtualUser")

local LocalPlayer = Players.LocalPlayer

--// EXECUTOR FUNCTIONS (feature-detect) //------------------------------------
local X = {
    hookfunction    = rawget(_G, "hookfunction"),
    newcclosure     = rawget(_G, "newcclosure"),
    instance_method = rawget(_G, "instance_method"),
    writefile       = rawget(_G, "writefile"),
    gethui          = rawget(_G, "gethui"),
}
if not X.newcclosure then X.newcclosure = function(f) return f end end

-- копирование ссылки в СИСТЕМНЫЙ буфер обмена Windows.
-- Пробуем все известные имена экзекуторов — какой-нибудь да сработает.
local function copyClipboard(text)
    local fns = {
        rawget(_G, "setclipboard"),
        rawget(_G, "toclipboard"),
        rawget(_G, "setrbxclipboard"),
        rawget(_G, "SetClipboard"),
    }
    -- API-таблицы
    for _, tname in ipairs({ "clipboard", "Clipboard", "syn", "fluxus", "solara", "secure", "cliptext" }) do
        local t = rawget(_G, tname)
        if type(t) == "table" then
            for _, mn in ipairs({ "set", "settext", "setClipboard", "write", "setText" }) do
                fns[#fns + 1] = t[mn]
            end
        end
    end
    for _, fn in ipairs(fns) do
        if type(fn) == "function" then
            local ok = pcall(fn, text)
            if ok then return true end
        end
    end
    return false
end

-- открыть ссылку: пробуем все известные имена функций открытия браузера
-- в глобалах и API-таблицах экзекуторов; если ничего нет — false
local OPEN_FNS = {
    "openurl", "OpenUrl", "openURL", "open_url", "OpenURL",
    "openbrowser", "OpenBrowser", "open_page", "OpenPage",
    "open_web", "OpenWebUrl", "open_link", "OpenLink",
    "openBrowser", "openWebPage", "browser", "OpenInBrowser",
}
local OPEN_TABLES = { "syn", "fluxus", "delta", "krnl", "hydrogen", "apollonium", "secure", "http", "solara" }

-- название экзекутора (если функция есть)
local function executorName()
    for _, name in ipairs({ "identifyexecutor", "getexecutorname", "get_name" }) do
        local fn = rawget(_G, name)
        if type(fn) == "function" then
            local ok, res = pcall(fn)
            if ok and type(res) == "string" then return res end
        end
    end
    return "неизвестный"
end

-- диагностика: какие функции открытия браузера реально есть в этой сборке
local function probeOpenUrl()
    local found = {}
    for _, name in ipairs(OPEN_FNS) do
        if type(rawget(_G, name)) == "function" then
            found[#found + 1] = name
        end
    end
    for _, tname in ipairs(OPEN_TABLES) do
        local t = rawget(_G, tname)
        if type(t) == "table" then
            for _, mn in ipairs(OPEN_FNS) do
                if type(t[mn]) == "function" then
                    found[#found + 1] = tname .. "." .. mn
                end
            end
        end
    end
    return found
end

local openUrl
openUrl = function(url)
    -- 1. глобальные функции
    for _, name in ipairs(OPEN_FNS) do
        local fn = rawget(_G, name)
        if type(fn) == "function" then
            local ok = pcall(fn, url)
            if ok then return true end
        end
    end
    -- 2. функции внутри API-таблиц (syn.openurl, fluxus.openurl и т.п.)
    for _, tname in ipairs(OPEN_TABLES) do
        local t = rawget(_G, tname)
        if type(t) == "table" then
            for _, name in ipairs(OPEN_FNS) do
                local fn = t[name]
                if type(fn) == "function" then
                    local ok = pcall(fn, url)
                    if ok then return true end
                end
            end
        end
    end
    -- 3. нативный messagebox Solara НЕ считается открытием браузера:
    --    это просто системное окошко. Открытии браузера им не добиться,
    --    поэтому здесь мы НЕ возвращаем true — копирование в буфер останется.
    return false
end

-- копирует ссылку сразу и ещё несколько раз в течение 3 секунд.
-- Roblox-клиент часто перезаписывает буфер обмена после записи,
-- поэтому повторные записи защищают от этого при переносе в браузер.
local function copyClipboardPersistent(text)
    local okFirst = copyClipboard(text)
    task.spawn(function()
        for _ = 1, 10 do
            task.wait(0.3)
            local f = _G.CandyFarm
            if not (f and f.running) then break end
            copyClipboard(text)
        end
    end)
    return okFirst
end

--// RE-RUN GUARD //-----------------------------------------------------------
if _G.CandyFarm and type(_G.CandyFarm.unload) == "function" then
    pcall(_G.CandyFarm.unload)
    task.wait(0.3)
end
if _G.CandyAutoCleanup and type(_G.CandyAutoCleanup) == "function" then
    pcall(_G.CandyAutoCleanup)
    task.wait(0.3)
end

--// STATE //------------------------------------------------------------------
local Farm = {
    running    = true,
    enabled    = false,
    teleport   = CONFIG.Teleport,
    collecting = false,
    afk        = false,       -- анти-AFK включён?
    lastAfk    = 0,           -- когда в последний раз «нажали»
    generation = 0,      -- растёт при каждом старт/стоп -> отменяет старые потоки
    unload     = nil,    -- проставляется ниже
}
_G.CandyFarm = Farm

local Connections = {}
local Threads     = {}
local LogLines    = {}
local SrvLog      = {}   -- что сервер присылал
local CallLog     = {}   -- что клиент отправлял (FireServer hook)
local Remotes     = {}   -- найденные ремоуты (для отчёта)
local Candy       = {}   -- id -> { id, pos, name, last, fails, try }
local CandyRemote = nil  -- лучший кандидат

local function addConn(c)
    table.insert(Connections, c)
    return c
end

--// LOG + GUI //--------------------------------------------------------------
local UI = {}

local function pushLog(line)
    table.insert(LogLines, tostring(line))
    while #LogLines > 200 do table.remove(LogLines, 1) end
    if UI.body then
        UI.body.Text = table.concat(LogLines, "\n")
        if UI.scroll then
            task.defer(function()
                pcall(function() UI.scroll.CanvasPosition = Vector2.new(0, UI.body.AbsoluteSize.Y) end)
            end)
        end
    end
    print("[CandyFarm] " .. tostring(line))
end

local function setStatus()
    if not UI.status then return end
    UI.status.Text = string.format("%s | %s%s | candy: %d | %s",
        Farm.enabled and "FARM: ON" or "FARM: OFF",
        Farm.teleport and "teleport" or "walk",
        Farm.afk and " | afk:ON" or "",
        (function() local n = 0 for _ in pairs(Candy) do n = n + 1 end return n end)(),
        CandyRemote and ("remote: " .. CandyRemote.Name) or "remote: —")
end

local function buildGui()
    local parent = (X.gethui and X.gethui()) or game:GetService("CoreGui")

    local gui = Instance.new("ScreenGui")
    gui.Name = "CandyFarmGui"
    gui.ResetOnSpawn = false
    gui.IgnoreGuiInset = true
    gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

    local ok = pcall(function() gui.Parent = parent end)
    if not ok then gui.Parent = LocalPlayer:WaitForChild("PlayerGui") end

    local WIDE, TALL, LOW = 430, 230, 34

    local frame = Instance.new("Frame")
    frame.Name = "Main"
    frame.Size = UDim2.new(0, WIDE, 0, TALL)
    frame.Position = UDim2.new(0, 20, 0, 80)
    frame.BackgroundColor3 = Color3.fromRGB(24, 14, 34)
    frame.BorderSizePixel = 0
    frame.Active = true
    frame.Parent = gui

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 12)
    corner.Parent = frame

    local stroke = Instance.new("UIStroke")
    stroke.Color = Color3.fromRGB(255, 128, 0)
    stroke.Transparency = 0.35
    stroke.Parent = frame

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, 0, 0, 26)
    title.BackgroundColor3 = Color3.fromRGB(46, 22, 56)
    title.BorderSizePixel = 0
    title.Font = Enum.Font.GothamBold
    title.TextSize = 13
    title.TextColor3 = Color3.fromRGB(255, 160, 40)
    title.Text = "  🎃 Candy Farm v4.3 · RE:Heads Please [RNG] 🎃"
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Parent = frame
    local tc = Instance.new("UICorner")
    tc.CornerRadius = UDim.new(0, 12)
    tc.Parent = title

    -- подпись автора, справа в шапке (клик = ссылка на Discord)
    local credit = Instance.new("TextButton")
    credit.Size = UDim2.new(0, 130, 0, 26)
    credit.Position = UDim2.new(1, -170, 0, 0)
    credit.BackgroundTransparency = 1
    credit.BorderSizePixel = 0
    credit.Font = Enum.Font.GothamBold
    credit.TextSize = 12
    credit.TextColor3 = Color3.fromRGB(255, 200, 120)
    credit.Text = "<u>Fluttershyᵗᵐ</u>"
    credit.RichText = true
    credit.TextXAlignment = Enum.TextXAlignment.Right
    credit.AutoButtonColor = true
    credit.Parent = frame
    -- курсор-указатель при наведении
    addConn(credit.MouseEnter:Connect(function()
        pcall(function() UserInputService.MouseIcon = "rbxasset://textures/ArrowFar.png" end)
    end))
    addConn(credit.MouseLeave:Connect(function()
        pcall(function()
            if UserInputService.MouseIcon == "rbxasset://textures/ArrowFar.png" then
                UserInputService.MouseIcon = "rbxasset://textures/ArrowCursor.png"
            end
        end)
    end))
    addConn(credit.MouseButton1Click:Connect(function()
        if CONFIG.DiscordUrl == "" then
            pushLog("! Discord-ссылка не задана — впиши её в CONFIG.DiscordUrl в шапке скрипта")
            return
        end
        local opened = openUrl(CONFIG.DiscordUrl)
        copyClipboardPersistent(CONFIG.DiscordUrl)
        if opened then
            pushLog("✅ Discord → " .. CONFIG.DiscordUrl .. " (попытка открыть браузер, ссылка в буфере)")
        else
            local pro = probeOpenUrl()
            pushLog("! не удалось открыть браузер (экзекутор: " .. executorName() .. ")")
            pushLog("! функций открытия URL найдено: " .. tostring(#pro) .. (next(pro) and ("  [" .. table.concat(pro, ", ") .. "]") or ""))
        end
    end))

    -- кнопка свернуть/развернуть (посажена внутрь шапки, чтобы не вылезала за рамку)
    local minBtn = Instance.new("TextButton")
    minBtn.Size = UDim2.new(0, 30, 0, 22)
    minBtn.Position = UDim2.new(1, -36, 0, 2)
    minBtn.BackgroundColor3 = Color3.fromRGB(46, 22, 56)
    minBtn.BorderSizePixel = 0
    minBtn.Font = Enum.Font.GothamBold
    minBtn.TextSize = 15
    minBtn.TextColor3 = Color3.fromRGB(255, 160, 40)
    minBtn.Text = "–"
    minBtn.Parent = frame

    local status = Instance.new("TextLabel")
    status.Size = UDim2.new(1, -16, 0, 20)
    status.Position = UDim2.new(0, 8, 0, 30)
    status.BackgroundTransparency = 1
    status.Font = Enum.Font.Code
    status.TextSize = 12
    status.TextColor3 = Color3.fromRGB(200, 150, 255)
    status.TextXAlignment = Enum.TextXAlignment.Left
    status.Text = "starting..."
    status.Parent = frame

    local scroll = Instance.new("ScrollingFrame")
    scroll.Size = UDim2.new(1, -16, 1, -100)
    scroll.Position = UDim2.new(0, 8, 0, 54)
    scroll.BackgroundColor3 = Color3.fromRGB(12, 8, 18)
    scroll.BorderSizePixel = 0
    scroll.ScrollBarThickness = 3
    scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
    scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
    scroll.Parent = frame
    local sc = Instance.new("UICorner")
    sc.CornerRadius = UDim.new(0, 6)
    sc.Parent = scroll

    local body = Instance.new("TextLabel")
    body.Size = UDim2.new(1, -8, 0, 0)
    body.Position = UDim2.new(0, 4, 0, 4)
    body.AutomaticSize = Enum.AutomaticSize.Y
    body.BackgroundTransparency = 1
    body.Font = Enum.Font.Code
    body.TextSize = 12
    body.TextColor3 = Color3.fromRGB(220, 200, 235)
    body.TextWrapped = true
    body.TextXAlignment = Enum.TextXAlignment.Left
    body.TextYAlignment = Enum.TextYAlignment.Top
    body.Text = ""
    body.Parent = scroll

    local row = Instance.new("Frame")
    row.Size = UDim2.new(1, -16, 0, 30)
    row.Position = UDim2.new(0, 8, 1, -38)
    row.BackgroundTransparency = 1
    row.Parent = frame
    local layout = Instance.new("UIListLayout")
    layout.FillDirection = Enum.FillDirection.Horizontal
    layout.Padding = UDim.new(0, 6)
    layout.Parent = row

    local function mkBtn(text, color, fn)
        local b = Instance.new("TextButton")
        b.Size = UDim2.new(0, 78, 1, 0)
        b.BackgroundColor3 = color
        b.BorderSizePixel = 0
        b.Font = Enum.Font.GothamBold
        b.TextSize = 12
        b.TextColor3 = Color3.fromRGB(20, 10, 24)
        b.Text = text
        b.Parent = row
        local c = Instance.new("UICorner")
        c.CornerRadius = UDim.new(0, 6)
        c.Parent = b
        addConn(b.MouseButton1Click:Connect(function()
            local ok2, err = pcall(fn)
            if not ok2 then pushLog("! button error: " .. tostring(err)) end
        end))
        return b
    end

    UI.gui     = gui
    UI.frame   = frame
    UI.status  = status
    UI.scroll  = scroll
    UI.body    = body
    UI.row     = row
    UI.btnStart = mkBtn("START", Color3.fromRGB(255, 150, 0), function() Farm.toggle() end)
    UI.btnAfk   = mkBtn("AFK",   Color3.fromRGB(80, 200, 120), function() Farm.toggleAfk() end)
    mkBtn("MODE",  Color3.fromRGB(150, 90, 220), function() Farm.toggleMode() end)
    mkBtn("DUMP",  Color3.fromRGB(150, 140, 165), function() Farm.dump() end)
    mkBtn("UNLOAD", Color3.fromRGB(220, 60, 60), function() Farm.unload() end)

    -- свернуть/развернуть окно
    local collapsed = false
    UI.minBtn = minBtn
    addConn(minBtn.MouseButton1Click:Connect(function()
        collapsed = not collapsed
        credit.Visible = not collapsed
        status.Visible = not collapsed
        scroll.Visible = not collapsed
        row.Visible = not collapsed
        frame.Size = UDim2.new(0, WIDE, 0, collapsed and LOW or TALL)
        minBtn.Text = collapsed and "+" or "–"
    end))

    -- перетаскивание окна мышью за заголовок
    local dragging, dragStart, startPos
    addConn(title.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = frame.Position
        end
    end))
    addConn(UserInputService.InputChanged:Connect(function(input)
        if not dragging then return end
        if input.UserInputType ~= Enum.UserInputType.MouseMovement
        and input.UserInputType ~= Enum.UserInputType.Touch then return end
        local d = input.Position - dragStart
        frame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X,
                                   startPos.Y.Scale, startPos.Y.Offset + d.Y)
    end))
    addConn(UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end))
end

--// UTILS //------------------------------------------------------------------
local function getChar()
    local char = LocalPlayer.Character
    if not char then return nil end
    return char:FindFirstChildOfClass("Humanoid"), char:FindFirstChild("HumanoidRootPart")
end

local function count(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

local function dump(v, depth, seen)
    depth = depth or 0
    seen  = seen or {}
    if depth > 3 then return "..." end
    local t = typeof(v)
    if t == "Vector3" then return string.format("V3(%.0f,%.0f,%.0f)", v.X, v.Y, v.Z) end
    if t == "CFrame"  then return string.format("CF(%.0f,%.0f,%.0f)", v.X, v.Y, v.Z) end
    if t == "Instance" then return v:GetFullName() end
    if t == "table" then
        if seen[v] then return "<cycle>" end
        seen[v] = true
        local parts, n = {}, 0
        for k, val in pairs(v) do
            n = n + 1
            if n > 10 then parts[#parts + 1] = "..." break end
            parts[#parts + 1] = tostring(k) .. "=" .. dump(val, depth + 1, seen)
        end
        seen[v] = nil
        return "{" .. table.concat(parts, ", ") .. "}"
    end
    return tostring(v)
end

-- приводим к Vector3 всё, что похоже на позицию
local function toVec3(v)
    if typeof(v) == "Vector3" then return v end
    if typeof(v) == "CFrame"  then return v.Position end
    if type(v) ~= "table" then return nil end
    if v.x and v.y and v.z then return Vector3.new(v.x, v.y, v.z) end
    if v.X and v.Y and v.Z then return Vector3.new(v.X, v.Y, v.Z) end
    for _, k in ipairs({ "position", "Position", "pos", "Pos", "location", "Location", "cframe", "CFrame" }) do
        local r = toVec3(v[k])
        if r then return r end
    end
    return nil
end

--// ХРАНИЛИЩЕ КОНФЕТ //-------------------------------------------------------
local function addCandy(id, pos, name)
    if not id or not pos then return end
    if count(Candy) > CONFIG.MaxTargets and not Candy[id] then return end
    local rec = Candy[id]
    if rec then
        rec.pos  = pos
        rec.last = os.clock()
    else
        Candy[id] = { id = id, pos = pos, name = name, last = os.clock(), fails = 0, try = 0 }
    end
end

local function removeCandy(payload, depth)
    depth = depth or 0
    if depth > 4 then return end
    if type(payload) == "string" or type(payload) == "number" then
        Candy[tostring(payload)] = nil
        return
    end
    if type(payload) ~= "table" then return end

    local id = payload.id or payload.Id or payload.ID or payload.uid or payload.key
    if id then Candy[tostring(id)] = nil return end

    local pos = toVec3(payload)
    if pos then
        local bestId, bestD
        for k, rec in pairs(Candy) do
            local d = (rec.pos - pos).Magnitude
            if not bestD or d < bestD then bestId, bestD = k, d end
        end
        if bestId and bestD and bestD < 15 then Candy[bestId] = nil end
        return
    end

    for _, v in pairs(payload) do removeCandy(v, depth + 1) end
end

-- разбор Snapshot: массив / словарь / вложенное, с подсказкой id из ключа
local function ingest(node, depth, seen, hintId)
    depth = depth or 0
    if depth > 4 or type(node) ~= "table" then return 0 end
    seen = seen or {}
    if seen[node] then return 0 end
    seen[node] = true

    if node[1] ~= nil then hintId = nil end  -- это массив, ключ не id

    local n  = 0
    local pos = toVec3(node)
    local id  = node.id or node.Id or node.ID or node.uid or node.Uid or node.key or hintId

    if id and pos then
        addCandy(tostring(id), pos, node.name or node.Name)
        n = n + 1
    end

    for k, v in pairs(node) do
        if type(v) == "table" then
            local hint = (type(k) ~= "number") and tostring(k) or nil
            n = n + ingest(v, depth + 1, seen, hint)
        end
    end
    return n
end

--// ПОИСК РЕМОУТОВ //---------------------------------------------------------
local function scoreName(full)
    local s = full:lower()
    local score = 0
    if s:find("candy")   then score = score + 10 end
    if s:find("collect") then score = score + 6 end
    if s:find("sync")    then score = score + 4 end
    if s:find("farm")    then score = score + 3 end
    if s:find("2026")    then score = score + 2 end
    if s:find("head")    then score = score + 1 end
    return score
end

local function isRemote(o)
    return o:IsA("RemoteEvent") or o:IsA("RemoteFunction")
end

local function discoverRemotes()
    local roots = { ReplicatedStorage }
    local found = {}

    local function scan(root)
        for _, o in ipairs(root:GetDescendants()) do
            if isRemote(o) then
                found[#found + 1] = {
                    obj   = o,
                    full  = o:GetFullName(),
                    name  = o.Name,
                    class = o.ClassName,
                    score = scoreName(o:GetFullName()),
                }
            end
        end
    end

    for _, r in ipairs(roots) do pcall(scan, r) end

    -- фоллбэк: если в ReplicatedStorage ремоутов нет — смотрим по всей игре
    if #found == 0 then
        pushLog("! в ReplicatedStorage ремоутов нет — сканирую всю игру (может занять пару секунд)")
        pcall(function()
            local i = 0
            for _, o in ipairs(game:GetDescendants()) do
                i = i + 1
                if i > 20000 then break end
                if isRemote(o) then
                    found[#found + 1] = {
                        obj = o, full = o:GetFullName(), name = o.Name,
                        class = o.ClassName, score = scoreName(o:GetFullName()),
                    }
                end
            end
        end)
    end

    table.sort(found, function(a, b)
        if a.score == b.score then return a.full < b.full end
        return a.score > b.score
    end)

    Remotes = found
    CandyRemote = found[1] and found[1].obj or nil
    return found
end

--// ОБРАБОТКА СОБЫТИЙ СЕРВЕРА //----------------------------------------------
local function handleServerEvent(obj, args)
    local raw = dump(args, 0)
    if #SrvLog < 60 then
        table.insert(SrvLog, string.format("%s  %s", obj:GetFullName(), raw))
    end
    pushLog("[srv] " .. obj.Name .. "  " .. raw)

    local key = ""
    if type(args[1]) == "string" then key = args[1]:lower() end
    local payload = args[2] or args[1]

    if key:find("snapshot") or key:find("sync")   or key:find("init")
    or key:find("list")     or key:find("update") or key:find("spawn")
    or key:find("state") then
        local n = ingest(payload)
        if n > 0 then pushLog(("  -> распознано конфет: %d (всего %d)"):format(n, count(Candy))) end
        setStatus()
    elseif key:find("collect") or key:find("remove") or key:find("taken")
        or key:find("delete")  or key:find("despawn") then
        removeCandy(payload)
        setStatus()
    else
        local n = ingest(payload)   -- неизвестное событие — всё равно пробуем разобрать
        if n > 0 then pushLog(("  -> (угадал) конфет: %d"):format(n)) ; setStatus() end
    end
end

--// HOOK ИСХОДЯЩИХ ВЫЗОВОВ (главный ответ на «как собирается») //-------------
local hookedAny = false

local function hookFireServer(remote)
    if not CONFIG.HookFireServer then return false end
    if not (X.hookfunction and X.instance_method) then return false end

    local ok = pcall(function()
        local old = X.hookfunction(X.instance_method(remote, "FireServer"), X.newcclosure(function(self, ...)
            local args = { ... }
            local line = string.format("%s  (%s)", remote:GetFullName(), dump(args, 0))
            if #CallLog < 60 then table.insert(CallLog, line) end
            pushLog("[call] " .. line)
            return old(self, ...)
        end))
        if old then hookedAny = true end
    end)
    return ok
end

local function attachRemotes()
    for _, r in ipairs(Remotes) do
        if r.obj:IsA("RemoteEvent") then
            local ok = pcall(function()
                addConn(r.obj.OnClientEvent:Connect(function(...)
                    local ok2, err = pcall(handleServerEvent, r.obj, { ... })
                    if not ok2 then pushLog("! event error: " .. tostring(err)) end
                end))
            end)
            if not ok then pushLog("! не смог подписаться на " .. r.full) end
            r.hooked = hookFireServer(r.obj) and true or false
        end
    end
end

--// ДВИЖЕНИЕ //---------------------------------------------------------------
local path = PathfindingService:CreatePath({
    AgentHeight = 5, AgentRadius = 2, AgentCanJump = false,
    AgentCanClimb = false, WaypointSpacing = 6,
})

local function teleportTo(pos)
    local _, hrp = getChar()
    if not hrp then return false end
    pcall(function()
        hrp.AssemblyLinearVelocity = Vector3.zero
        hrp.CFrame = CFrame.new(pos + Vector3.new(0, 3, 0))
    end)
    task.wait(0.12)
    return true
end

local function walkTo(target, generation)
    local hum, hrp = getChar()
    if not hum or not hrp then return false end

    local deadline = os.clock() + CONFIG.ArriveTimeout
    local function cancelled()
        return generation ~= Farm.generation or not Farm.running or not Farm.enabled
    end

    local ok = pcall(function() path:ComputeAsync(hrp.Position, target) end)
    local waypoints = (ok and path.Status == Enum.PathStatus.Success) and path:GetWaypoints() or nil

    if not waypoints or #waypoints < 2 then
        hum:MoveTo(target)
    else
        for i = 2, #waypoints do
            if cancelled() then return false end
            if os.clock() > deadline then break end
            local wp = waypoints[i]
            hum:MoveTo(wp.Position)
            local wpDeadline = math.min(deadline, os.clock() + 3)
            repeat
                if cancelled() then return false end
                task.wait(0.1)
                local _, r = getChar()
                if not r then return false end
                local need = (wp.Action == Enum.PathWaypointAction.Jump) and 6 or 3
                if (r.Position - wp.Position).Magnitude < need then break end
            until os.clock() > wpDeadline
        end
        hum:MoveTo(target)
    end

    repeat
        if cancelled() then return false end
        task.wait(0.1)
        local _, r = getChar()
        if not r then return false end
        if (r.Position - target).Magnitude <= CONFIG.WalkDistance then return true end
    until os.clock() > deadline

    return false
end

--// СБОР //-------------------------------------------------------------------
local function attemptCollect(rec)
    if not CONFIG.AutoCollect or not CandyRemote then return end
    local calls = CONFIG.CollectCalls
    if #calls == 0 then return end

    rec.try = ((rec.try or 0) % #calls) + 1
    local proto = calls[rec.try]
    local args = {}
    for i = 2, #proto do
        args[#args + 1] = (proto[i] == "%id%") and rec.id or proto[i]
    end

    local ok, err = pcall(function() CandyRemote:FireServer(proto[1], table.unpack(args)) end)
    pushLog(string.format("  ~ collect try %d: %s(%s) -> %s",
        rec.try, proto[1], table.concat(args, ","), ok and "sent" or ("err " .. tostring(err))))
end

local function collectAll()
    if Farm.collecting then return end
    Farm.collecting = true
    local generation = Farm.generation

    local list = {}
    local _, hrp = getChar()
    if hrp then
        for _, rec in pairs(Candy) do
            if os.clock() - rec.last <= CONFIG.FreshFor and rec.fails < CONFIG.GiveUpAfter then
                local d = (rec.pos - hrp.Position).Magnitude
                if d > 0.5 and d <= CONFIG.MaxTargetDist then
                    rec.dist = d
                    table.insert(list, rec)
                end
            end
        end
        table.sort(list, function(a, b) return a.dist < b.dist end)
    end

    if #list == 0 then
        Farm.collecting = false
        return
    end

    pushLog(("беру %d шт. [%s]"):format(#list, Farm.teleport and "teleport" or "walk"))

    for _, rec in ipairs(list) do
        if not Farm.running or not Farm.enabled or generation ~= Farm.generation then break end
        if Candy[rec.id] == nil then continue end

        local okMove
        if Farm.teleport then okMove = teleportTo(rec.pos) else okMove = walkTo(rec.pos, generation) end
        task.wait(0.2)

        if Candy[rec.id] == nil then
            pushLog("  + собрана: " .. tostring(rec.id))
            Candy[rec.id] = nil
            setStatus()
        else
            rec.fails = (rec.fails or 0) + 1
            if okMove then
                attemptCollect(rec)
                task.wait(0.25)
                if Candy[rec.id] == nil then
                    pushLog("  + собрана после запроса: " .. tostring(rec.id))
                    setStatus()
                else
                    rec.fails = (rec.fails or 0) + 1
                    pushLog(("  ? не поддаётся (%d/%d): %s"):format(rec.fails, CONFIG.GiveUpAfter, tostring(rec.id)))
                end
            else
                pushLog("  ? не дошёл до " .. tostring(rec.id))
            end
        end
    end

    Farm.collecting = false
end

--// ОТЧЁТ / БУФЕР / ФАЙЛ //---------------------------------------------------
local function buildReport()
    local out = {}
    local function L(s) out[#out + 1] = s or "" end

    L("================= CANDY FARM v4 (HALLOWEEN) — REPORT =================")
    L(("игрок: %s | время: %s"):format(LocalPlayer.Name, os.date("%Y-%m-%d %H:%M:%S")))
    L("script by Fluttershyᵗᵐ  🎃")
    L("discord: " .. CONFIG.DiscordUrl)
    L(("режим: %s | сбор: %s | hook FireServer: %s")
        :format(Farm.teleport and "teleport" or "walk",
                CONFIG.AutoCollect and "on" or "off",
                hookedAny and "поставлен" or "недоступен"))
    L("")

    L("-- 1. РЕМОУТЫ (ReplicatedStorage), по убыванию релевантности --")
    if #Remotes == 0 then
        L("   пусто — похоже, ремоутов в ReplicatedStorage нет")
    else
        for _, r in ipairs(Remotes) do
            L(("   %-46s %-13s score=%-3d%s"):format(r.full, r.class, r.score, r.hooked and " [hook]" or ""))
        end
    end
    L("")

    L("-- 2. ЧТО КЛИЕНТ ОТПРАВЛЯЛ (перехвачено hook'ом) --")
    if #CallLog == 0 then
        L("   пусто. СОБЕРИ ОДНУ КОНФЕТУ РУКАМИ с запущенным скриптом —")
        L("   и она появится здесь: это и есть настоящий протокол сбора.")
    else
        for _, l in ipairs(CallLog) do L("   " .. l) end
    end
    L("")

    L("-- 3. ЧТО ПРИСЫЛАЛ СЕРВЕР --")
    if #SrvLog == 0 then
        L("   пусто — сервер молчит: значит список приходит только по запросу")
        L("   (или ремоут найден не тот).")
    else
        for _, l in ipairs(SrvLog) do L("   " .. l) end
    end
    L("")

    L(("-- 4. КОНФЕТЫ В ПАМЯТИ: %d --"):format(count(Candy)))
    local _, hrp = getChar()
    local rows = {}
    for _, rec in pairs(Candy) do
        rows[#rows + 1] = {
            id = tostring(rec.id),
            d = hrp and (rec.pos - hrp.Position).Magnitude or -1,
            f = rec.fails or 0,
        }
    end
    table.sort(rows, function(a, b) return a.d < b.d end)
    for i = 1, math.min(#rows, 25) do
        L(("   %-28s ~%7.1f studs  fails=%d"):format(rows[i].id, rows[i].d, rows[i].f))
    end
    if #rows == 0 then L("   пусто — смотри разделы 2 и 3") end

    L("")
    L("================= END =================")
    return table.concat(out, "\n")
end

Farm.dump = function()
    local rep = buildReport()
    pushLog("--- отчёт ---")
    for _, l in ipairs(string.split and {} or {}) do end -- no-op placeholder
    for i, line in ipairs({ string.match(rep, "[^\n]*\n?") }) do end
    -- печатаем отчёт в окно порциями строк
    for chunk in rep:gmatch("[^\n]*\n?") do
        if chunk ~= "" then pushLog(chunk) end
    end
    if X.writefile then
        local ok = pcall(X.writefile, "candy_report.txt", rep)
        pushLog(ok and "отчёт сохранён в candy_report.txt" or "! writefile не сработал")
    else
        pushLog("! writefile недоступен — сохранение в файл пропущено")
    end
end

Farm.copy = function()
    local rep = buildReport()
    local ok = copyClipboard(rep)
    pushLog(ok and "отчёт скопирован в буфер обмена (Ctrl+V)" or "! копирование в буфер не сработало")
end

--// ANTI-AFK //---------------------------------------------------------------
local function doAfkTick()
    -- 1. «нажатие» случайной клавиши через VirtualInputManager
    local keysOk = false
    pcall(function()
        local keys = CONFIG.AfkKeys
        if #keys > 0 then
            local k = keys[math.random(#keys)]
            VirtualInputManager:SendKeyEvent(true, k, false, game)
            task.wait(0.08)
            VirtualInputManager:SendKeyEvent(false, k, false, game)
            keysOk = true
        end
    end)
    -- 2. страховка: классический анти-афк (движение мыши через VirtualUser)
    pcall(function()
        VirtualUser:CaptureController()
        VirtualUser:ClickButton2(Vector2.zero)
    end)
    if keysOk then
        pushLog("[afk] нажата клавиша (anti-AFK)")
    else
        pushLog("[afk] клик через VirtualUser (anti-AFK)")
    end
    setStatus()
end

Farm.toggleAfk = function()
    Farm.afk = not Farm.afk
    Farm.lastAfk = Farm.afk and os.clock() or 0
    pushLog("ANTI-AFK " .. (Farm.afk and ("ON (клавиша каждые " .. CONFIG.AfkInterval .. " c)") or "OFF"))
    if UI.btnAfk then
        UI.btnAfk.Text = Farm.afk and "AFK:ON" or "AFK"
    end
    setStatus()
end

--// УПРАВЛЕНИЕ //-------------------------------------------------------------
Farm.start = function()
    Farm.generation = Farm.generation + 1
    Farm.enabled = true
    pushLog("FARM ON [" .. (Farm.teleport and "teleport" or "walk") .. "]")
    setStatus()
    if UI.btnStart then UI.btnStart.Text = "STOP" end
end

Farm.stop = function()
    Farm.generation = Farm.generation + 1
    Farm.enabled = false
    pushLog("FARM OFF")
    setStatus()
    if UI.btnStart then UI.btnStart.Text = "START" end
end

Farm.toggle = function()
    if Farm.enabled then Farm.stop() else Farm.start() end
end

Farm.toggleMode = function()
    Farm.teleport = not Farm.teleport
    pushLog("режим: " .. (Farm.teleport and "teleport" or "walk"))
    setStatus()
end

Farm.scan = function()
    discoverRemotes()
    attachRemotes()
    pushLog(("найдено ремоутов: %d | лучший: %s")
        :format(#Remotes, CandyRemote and CandyRemote:GetFullName() or "—"))
    setStatus()
end

Farm.requestSync = function()
    if not CONFIG.RequestSync or not CandyRemote then return end
    for _, cmd in ipairs(CONFIG.SyncCalls) do
        pcall(function() CandyRemote:FireServer(cmd) end)
    end
end

--// UNLOAD //-----------------------------------------------------------------
Farm.unload = function()
    if not Farm.running then return end
    Farm.running = false
    Farm.enabled = false
    Farm.afk = false
    Farm.generation = Farm.generation + 1

    for _, th in ipairs(Threads) do pcall(task.cancel, th) end
    table.clear(Threads)

    for _, c in ipairs(Connections) do pcall(function() c:Disconnect() end) end
    table.clear(Connections)

    table.clear(Candy)
    table.clear(SrvLog)
    table.clear(CallLog)
    table.clear(Remotes)

    if UI.gui then pcall(function() UI.gui:Destroy() end) end
    UI = {}

    _G.CandyFarm = nil
    _G.CandyAutoCleanup = nil
    pcall(function()
        if game:GetService("StarterGui") then
            game:GetService("StarterGui"):SetCore("SendNotification", {
                Title = "Candy Farm v4 (Halloween)", Text = "Скрипт выгружен", Duration = 3,
            })
        end
    end)
    print("[CandyFarm] unloaded")
end

-- заодно совместимость со старым именем
_G.CandyAutoCleanup = function() pcall(Farm.unload) end

--// HOTKEYS //----------------------------------------------------------------
local function onKey(key, fn)
    return addConn(UserInputService.InputBegan:Connect(function(input, gpe)
        if gpe or input.KeyCode ~= key then return end
        if UserInputService:GetFocusedTextBox() then return end
        local ok, err = pcall(fn)
        if not ok then pushLog("! key error: " .. tostring(err)) end
    end))
end

--// BOOT //-------------------------------------------------------------------
buildGui()
pushLog("Candy Farm v4.3 · Halloween 🎃 · by Fluttershyᵗᵐ")
pushLog("Discord: " .. CONFIG.DiscordUrl .. " (клик по подписи в окне)")

-- автоматически кладём ссылку в системный буфер обмена при старте
task.spawn(function()
    task.wait(1)
    if copyClipboardPersistent(CONFIG.DiscordUrl) then
        pushLog("✅ ссылка Discord в буфере обмена — нажми CTRL+V в браузере")
    else
        pushLog("! не удалось скопировать ссылку — нажми на подпись Fluttershyᵗᵐ в окне")
    end
end)

task.spawn(function()
    if not Farm.running then return end
    discoverRemotes()
    attachRemotes()
    pushLog(("ремоутов найдено: %d | кандидат: %s")
        :format(#Remotes, CandyRemote and CandyRemote:GetFullName() or "НЕТ"))
    if not hookedAny then
        pushLog("! hook FireServer недоступен в этой сборке — раздел 2 отчёта будет пуст")
    else
        pushLog("hook поставлен: собери одну конфету руками, вызов появится в логе")
    end
    setStatus()

    -- запрашиваем список один раз при старте и дальше по интервалу
    Farm.requestSync()
end)

table.insert(Threads, task.spawn(function()
    local lastSync = os.clock()
    while Farm.running do
        local ok, err = pcall(function()
            if os.clock() - lastSync >= CONFIG.SyncInterval then
                lastSync = os.clock()
                Farm.requestSync()
            end
            if Farm.enabled and not Farm.collecting then
                collectAll()
            else
                task.wait(0.2)
            end
        end)
        if not ok then pushLog("! loop error: " .. tostring(err)) end
        task.wait(0.1)
    end
end))

table.insert(Threads, task.spawn(function()
    while Farm.running do
        task.wait(1)
        if Farm.afk and os.clock() - Farm.lastAfk >= CONFIG.AfkInterval then
            Farm.lastAfk = os.clock()
            local ok, err = pcall(doAfkTick)
            if not ok then pushLog("! afk error: " .. tostring(err)) end
        end
    end
end))

onKey(CONFIG.ToggleKey, function() Farm.toggle() end)
onKey(CONFIG.DumpKey,   function() Farm.dump() end)
onKey(CONFIG.ModeKey,   function() Farm.toggleMode() end)
onKey(CONFIG.AfkKey,    function() Farm.toggleAfk() end)
onKey(CONFIG.UnloadKey, function() Farm.unload() end)

pushLog("готов. F1 старт/стоп · F2 отчёт · F3 режим · F4 анти-AFK · F6 unload")
setStatus()