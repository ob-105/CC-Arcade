local protocol = dofile("/shared/protocol.lua")
local security = dofile("/shared/security.lua")
local net = dofile("/shared/net.lua")

local MACHINE_ID = "frontdesk-01"
local ROLE = "admin"
local TOKEN_FILE = "/arcade_token.txt"

local config = {
    requestTimeout = 5,
    serverId = nil,
}

local state = {
    players = {},
    selectedIndex = 1,
    logs = {},
    message = "Ready",
    isError = false,
}

local buttons = {}

-- ══════════════════════════════════════════════════════════
--  PALETTE
-- ══════════════════════════════════════════════════════════
local P = {
    headerBg     = colors.blue,
    headerFg     = colors.white,
    subBg        = colors.lightBlue,
    subFg        = colors.white,
    panelBg      = colors.gray,
    panelTitleBg = colors.blue,
    panelTitleFg = colors.white,
    rowBg        = colors.gray,
    rowFg        = colors.white,
    rowAltBg     = colors.lightGray,
    rowAltFg     = colors.black,
    selBg        = colors.cyan,
    selFg        = colors.black,
    keyFg        = colors.lightBlue,
    valFg        = colors.white,
    badgeFg      = colors.black,
    msgBg        = colors.black,
    msgOkFg      = colors.lime,
    msgErrFg     = colors.red,
    modalBg      = colors.gray,
    modalBar     = colors.blue,
    modalFg      = colors.white,
    modalPrompt  = colors.lightBlue,
    screenBg     = colors.black,
}

-- badge colour per transaction type
local function txBadgeColor(txType)
    if txType == "award" or txType == "adjust" then return colors.lime    end
    if txType == "spend"                         then return colors.red    end
    if txType == "create"                        then return colors.cyan   end
    if txType == "rename" or txType == "link_card" then return colors.yellow end
    return colors.lightGray
end

-- ══════════════════════════════════════════════════════════
--  PRIMITIVES
-- ══════════════════════════════════════════════════════════
local function fillRect(x, y, w, h, bg, fg)
    term.setBackgroundColor(bg)
    if fg then term.setTextColor(fg) end
    local row = string.rep(" ", w)
    for dy = 0, h - 1 do
        term.setCursorPos(x, y + dy)
        term.write(row)
    end
end

local function writeAt(x, y, text, bg, fg)
    if bg then term.setBackgroundColor(bg) end
    if fg then term.setTextColor(fg)       end
    term.setCursorPos(x, y)
    term.write(text)
end

local function clampText(text, width)
    text = tostring(text or "")
    if #text <= width then return text end
    if width <= 3      then return string.sub(text, 1, width) end
    return string.sub(text, 1, width - 3) .. "\133"
end

local function padRight(text, width)
    text = tostring(text or "")
    if #text >= width then return string.sub(text, 1, width) end
    return text .. string.rep(" ", width - #text)
end

local function clear()
    term.setBackgroundColor(P.screenBg)
    term.setTextColor(P.headerFg)
    term.clear()
    term.setCursorPos(1, 1)
end

local function setMessage(message, isError)
    state.message = message or ""
    state.isError = isError == true
end

-- ──────────────────────────────────────────────────────────
--  MODAL ask() — styled overlay
-- ──────────────────────────────────────────────────────────
local function ask(title, prompts)
    local W, H = term.getSize()
    local mw = math.min(44, W - 4)
    local mh = #prompts + 4
    local mx = math.floor((W - mw) / 2) + 1
    local my = math.floor((H - mh) / 2)

    -- dark backdrop
    term.setBackgroundColor(colors.black)
    for row = 1, H do
        term.setCursorPos(1, row)
        term.write(string.rep(" ", W))
    end

    -- modal body
    fillRect(mx, my, mw, mh, P.modalBg, P.modalFg)

    -- title bar
    fillRect(mx, my, mw, 1, P.modalBar, P.headerFg)
    local ts = " " .. title .. " "
    writeAt(mx + math.floor((mw - #ts) / 2), my, ts, P.modalBar, P.headerFg)

    -- hint bar
    fillRect(mx, my + mh - 1, mw, 1, P.modalBar, P.headerFg)
    writeAt(mx + 1, my + mh - 1, clampText("Enter to confirm  \xb7  blank to cancel", mw - 2), P.modalBar, P.headerFg)

    local values = {}
    for i, prompt in ipairs(prompts) do
        local py = my + 1 + i
        writeAt(mx + 2, py, padRight(prompt .. ":", mw - 4), P.modalBg, P.modalPrompt)
        term.setCursorPos(mx + 2 + #prompt + 2, py)
        term.setBackgroundColor(P.modalBg)
        term.setTextColor(P.modalFg)
        term.setCursorBlink(true)
        values[i] = read()
        term.setCursorBlink(false)
    end

    return values
end

local function send(messageType, payload)
    local token = security.loadToken(TOKEN_FILE)
    local request = protocol.makeRequest(MACHINE_ID, ROLE, token, messageType, payload)
    local ok, response, err = net.sendRequest(config.serverId, request, config.requestTimeout)
    if not ok then
        return false, nil, err
    end

    if not response.ok then
        return false, nil, response.error
    end

    return true, response.data, nil
end

local function requireServer()
    if config.serverId then
        return true
    end

    local token = security.loadToken(TOKEN_FILE)
    local serverId, err = net.discoverServer(MACHINE_ID, ROLE, token, 3)
    if not serverId then
        setMessage("Server discovery failed: " .. tostring(err), true)
        return false
    end

    config.serverId = serverId
    setMessage("Connected to server id " .. tostring(serverId), false)
    return true
end

local function parseCardFile(path)
    if not fs.exists(path) then
        return nil
    end

    local file = fs.open(path, "r")
    if not file then
        return nil
    end

    local card = {}
    while true do
        local line = file.readLine()
        if not line then
            break
        end

        local key, value = string.match(line, "^(%w+)%s*=%s*(.+)$")
        if key and value then
            card[key] = value
        end
    end

    file.close()
    return card.cardId and card or nil
end

local function generateCardId()
    local n = math.random(0x10000000, 0xFFFFFFFF)
    local m = math.random(0x1000, 0xFFFF)
    return string.format("AC-%08X-%04X", n, m)
end

local function refreshPlayers(search)
    local ok, data, err = send("player.list", { search = search })
    if not ok then
        setMessage("Player refresh failed: " .. tostring(err), true)
        return false
    end

    state.players = data.items or {}
    if #state.players == 0 then
        state.selectedIndex = 1
    else
        state.selectedIndex = math.min(math.max(state.selectedIndex, 1), #state.players)
    end
    return true
end

local function refreshLogs()
    local payload = { limit = 8 }
    local player = state.players[state.selectedIndex]
    if player then
        payload.playerId = player.playerId
    end

    local ok, data, err = send("tx.listRecent", payload)
    if not ok then
        setMessage("Log refresh failed: " .. tostring(err), true)
        return false
    end

    state.logs = data.items or {}
    return true
end

local function refreshAll()
    if not requireServer() then
        return false
    end

    local playersOk = refreshPlayers(nil)
    local logsOk = refreshLogs()
    return playersOk and logsOk
end

local function currentPlayer()
    return state.players[state.selectedIndex]
end

local function createPlayerAction()
    local values = ask("Create Player", { "Display name" })
    if values[1] == "" then
        setMessage("Create cancelled", false)
        return
    end

    local ok, data, err = send("player.create", { displayName = values[1] })
    if not ok then
        setMessage("Create failed: " .. tostring(err), true)
        return
    end

    setMessage("Created " .. data.player.displayName, false)
    refreshAll()
end

local function renamePlayerAction()
    local player = currentPlayer()
    if not player then
        setMessage("No player selected", true)
        return
    end

    local values = ask("Rename Player", { "New display name" })
    if values[1] == "" then
        setMessage("Rename cancelled", false)
        return
    end

    local ok, data, err = send("player.rename", {
        playerId = player.playerId,
        newDisplayName = values[1],
    })
    if not ok then
        setMessage("Rename failed: " .. tostring(err), true)
        return
    end

    setMessage("Renamed to " .. data.player.displayName, false)
    refreshAll()
end

local function findActiveDriveSide()
    for _, side in ipairs(peripheral.getNames()) do
        if peripheral.getType(side) == "drive" and disk.isPresent(side) then
            return side
        end
    end
    return nil
end

local function issueCardAction()
    local driveSide = findActiveDriveSide()
    if not driveSide or not fs.exists("/disk") then
        setMessage("No floppy disk in drive", true)
        return
    end

    local cardId = generateCardId()
    local file = fs.open("/disk/arcade_card.txt", "w")
    if not file then
        setMessage("Failed to write card file", true)
        return
    end

    file.writeLine("cardId=" .. cardId)
    file.writeLine("version=1")
    file.writeLine("issuedAt=" .. tostring(os.epoch("utc")))
    file.close()
    pcall(disk.setLabel, driveSide, "Arcade Card " .. string.sub(cardId, -4))

    setMessage("Issued card " .. cardId, false)
end

local function linkCardAction()
    local player = currentPlayer()
    if not player then
        setMessage("No player selected", true)
        return
    end

    local card = parseCardFile("/disk/arcade_card.txt")
    if not card then
        setMessage("No valid card file in /disk", true)
        return
    end

    local ok, data, err = send("player.linkCard", {
        playerId = player.playerId,
        cardId = card.cardId,
    })
    if not ok then
        setMessage("Link failed: " .. tostring(err), true)
        return
    end

    setMessage("Linked card to " .. data.player.displayName, false)
    refreshAll()
end

local function loadCreditsAction()
    local player = currentPlayer()
    if not player then
        setMessage("No player selected", true)
        return
    end

    local values = ask("Load Credits", { "Amount" })
    if values[1] == "" then
        setMessage("Load credits cancelled", false)
        return
    end

    local amount = tonumber(values[1])
    if not amount or amount <= 0 or amount ~= math.floor(amount) then
        setMessage("Amount must be a positive whole number", true)
        return
    end

    local ok, data, err = send("tickets.add", {
        playerId = player.playerId,
        amount = amount,
        note = "Front desk credit load",
    })
    if not ok then
        setMessage("Load credits failed: " .. tostring(err), true)
        return
    end

    if data and data.bypassed then
        setMessage("Ticket mode disabled; credits unchanged", true)
    else
        setMessage("Loaded " .. tostring(amount) .. " credits to " .. player.displayName, false)
    end
    refreshAll()
end

local function searchAction()
    local values = ask("Search Players", { "Search text" })
    if refreshPlayers(values[1]) then
        refreshLogs()
        setMessage("Search applied", false)
    end
end

local function refreshAction()
    if refreshAll() then
        setMessage("Refreshed", false)
    end
end

local function inside(button, x, y)
    return x >= button.x and x <= (button.x + button.w - 1)
       and y >= button.y and y <= (button.y + button.h - 1)
end

-- ──────────────────────────────────────────────────────────
--  BUTTONS  (2 rows tall: label on top, [key] below)
-- ──────────────────────────────────────────────────────────
local function drawButton(btn)
    local fg = btn.fg or colors.black
    fillRect(btn.x, btn.y, btn.w, btn.h, btn.bg, fg)
    -- label row
    local label  = clampText(btn.label, btn.w - 2)
    local labelX = btn.x + math.floor((btn.w - #label) / 2)
    writeAt(labelX, btn.y, label, btn.bg, fg)
    -- hotkey hint row (if 2-row button)
    if btn.h >= 2 then
        local hint  = "[" .. btn.key .. "]"
        local hintX = btn.x + math.floor((btn.w - #hint) / 2)
        writeAt(hintX, btn.y + 1, hint, btn.bg, colors.lightGray)
    end
end

local BUTTON_COLS = 4
local BUTTON_ROWS_H = 2
local BUTTON_AREA_H = BUTTON_ROWS_H * 2

local function rebuildButtons()
    local width, height = term.getSize()
    local specs = {
        { key = "1", label = "Search",   action = searchAction,       bg = colors.cyan      },
        { key = "2", label = "Create",   action = createPlayerAction, bg = colors.lightBlue },
        { key = "3", label = "Rename",   action = renamePlayerAction, bg = colors.orange    },
        { key = "4", label = "Issue",    action = issueCardAction,    bg = colors.yellow    },
        { key = "5", label = "Link",     action = linkCardAction,     bg = colors.lime      },
        { key = "6", label = "Refresh",  action = refreshAction,      bg = colors.gray,   fg = colors.white },
        { key = "7", label = "Load",     action = loadCreditsAction,  bg = colors.purple, fg = colors.white },
        { key = "0", label = "Exit",     action = nil,                bg = colors.red,    fg = colors.white },
    }

    local cols   = BUTTON_COLS
    local rows   = math.ceil(#specs / cols)
    local gapX   = 1
    local bh     = BUTTON_ROWS_H
    local usable = width - 2 - ((cols - 1) * gapX)
    local bw     = math.max(6, math.floor(usable / cols))
    local startY = height - rows * bh + 1

    buttons = {}
    for i, spec in ipairs(specs) do
        local row = math.floor((i - 1) / cols)
        local col = (i - 1) % cols
        table.insert(buttons, {
            key    = spec.key,
            label  = spec.label,
            action = spec.action,
            x = 2 + col * (bw + gapX),
            y = startY + row * bh,
            w = bw,
            h = bh,
            bg = spec.bg,
            fg = spec.fg,
        })
    end
end

-- ──────────────────────────────────────────────────────────
--  PANEL helper: draw a titled panel box
-- ──────────────────────────────────────────────────────────
local function drawPanelHeader(x, y, w, title, icon)
    fillRect(x, y, w, 1, P.panelTitleBg, P.panelTitleFg)
    local label = " " .. (icon or "\x10") .. " " .. title .. " "
    writeAt(x, y, clampText(label, w), P.panelTitleBg, P.panelTitleFg)
end

-- ──────────────────────────────────────────────────────────
--  PLAYERS panel
-- ──────────────────────────────────────────────────────────
local function drawPlayersPanel(x, y, w, h)
    drawPanelHeader(x, y, w, "Players (" .. tostring(#state.players) .. ")", "\x02")

    for row = 1, h - 1 do
        local lineY  = y + row
        local player = state.players[row]
        if player then
            local sel   = (row == state.selectedIndex)
            local even  = (row % 2 == 0)
            local bg    = sel and P.selBg or (even and P.rowAltBg or P.rowBg)
            local fg    = sel and P.selFg or (even and P.rowAltFg or P.rowFg)
            fillRect(x, lineY, w, 1, bg, fg)
            local prefix = sel and "\x10 " or "  "
            writeAt(x, lineY, prefix .. clampText(player.displayName, w - 2), bg, fg)
        else
            fillRect(x, lineY, w, 1, P.panelBg, P.panelBg)
        end
    end
end

-- ──────────────────────────────────────────────────────────
--  DETAILS panel
-- ──────────────────────────────────────────────────────────
local function drawDetailsPanel(x, y, w, h)
    drawPanelHeader(x, y, w, "Details", "\x04")
    fillRect(x, y + 1, w, h - 1, P.panelBg, P.valFg)

    local player = currentPlayer()
    if not player then
        writeAt(x + 2, y + 2, "No player selected", P.panelBg, colors.lightGray)
        return
    end

    -- each field: { key label, value }
    local fields = {
        { "Name",   player.displayName          },
        { "Card",   tostring(player.cardId or "none") },
        { "ID",     player.playerId             },
        { "Tickets","(disabled)"                },
    }

    for i, field in ipairs(fields) do
        local fy = y + i * 2 - 1
        if fy + 1 >= y + h then break end
        -- key label
        writeAt(x + 1, fy,     clampText(field[1], w - 2), P.panelBg, P.keyFg)
        -- value (indented)
        writeAt(x + 1, fy + 1, clampText(field[2], w - 2), P.panelBg, P.valFg)
    end
end

-- ──────────────────────────────────────────────────────────
--  LOGS panel
-- ──────────────────────────────────────────────────────────
local function drawLogsPanel(x, y, w, h)
    local player = currentPlayer()
    local title  = player and ("Txns: " .. clampText(player.displayName, w - 10)) or "Transactions"
    drawPanelHeader(x, y, w, title, "\x05")
    fillRect(x, y + 1, w, h - 1, P.panelBg, P.valFg)

    for row = 1, h - 1 do
        local lineY = y + row
        local tx    = state.logs[row]
        if tx then
            local badge = clampText(tx.type, 8)
            local bc    = txBadgeColor(tx.type)
            local amt   = tostring(tx.amount or 0)

            -- badge chip
            writeAt(x + 1, lineY, " " .. badge .. " ", bc, P.badgeFg)
            -- amount
            local amtX = x + 1 + #badge + 3
            if amtX + #amt < x + w then
                writeAt(amtX, lineY, amt, P.panelBg, colors.lightGray)
            end
        else
            fillRect(x, lineY, w, 1, P.panelBg, P.panelBg)
        end
    end
end

-- ──────────────────────────────────────────────────────────
--  FULL DASHBOARD
-- ──────────────────────────────────────────────────────────
local function drawDashboard()
    clear()
    local W, H = term.getSize()

    -- layout constants
    local HEADER_H  = 3
    local FOOTER_H  = 1   -- message bar
    local BTN_H     = BUTTON_AREA_H
    local top       = HEADER_H + 1
    local contentH  = math.max(4, H - top - FOOTER_H - BTN_H - 1)
    local leftW     = math.max(16, math.floor(W * 0.28))
    local midW      = math.max(18, math.floor(W * 0.34))
    local rightW    = math.max(12, W - leftW - midW - 4)
    local col2      = leftW + 3
    local col3      = col2 + midW + 1

    -- ── HEADER ──────────────────────────────────────────
    fillRect(1, 1, W, 1, P.headerBg, P.headerFg)
    writeAt(2, 1, "\x06 ARCADE FRONT DESK", P.headerBg, P.headerFg)
    local clock = os.date("%H:%M:%S")
    writeAt(W - #clock - 1, 1, clock, P.headerBg, colors.lightBlue)

    fillRect(1, 2, W, 1, P.subBg, P.subFg)
    local srv    = "Server: " .. tostring(config.serverId or "discovering\x85")
    local pcount = "Players: " .. tostring(#state.players)
    writeAt(2,         2, srv,    P.subBg, P.subFg)
    writeAt(W - #pcount - 1, 2, pcount, P.subBg, colors.white)

    -- divider
    fillRect(1, 3, W, 1, P.panelBg, P.panelBg)

    -- ── PANELS ──────────────────────────────────────────
    drawPlayersPanel(2,    top, leftW, contentH)
    drawDetailsPanel(col2, top, midW,  contentH)
    drawLogsPanel   (col3, top, rightW,contentH)

    -- column separators (just a dark strip between panels)
    for dy = 0, contentH - 1 do
        writeAt(col2 - 1, top + dy, " ", P.screenBg, P.screenBg)
        writeAt(col3 - 1, top + dy, " ", P.screenBg, P.screenBg)
    end

    -- ── MESSAGE BAR ─────────────────────────────────────
    local msgY  = H - BTN_H - 1
    fillRect(1, msgY, W, 1, P.msgBg, P.msgBg)
    local stripe = state.isError and "\x16" or "\x16"
    local stripC = state.isError and colors.red or colors.lime
    writeAt(1, msgY, stripe, stripC, stripC)
    writeAt(3, msgY, clampText(state.message, W - 4), P.msgBg,
        state.isError and P.msgErrFg or P.msgOkFg)

    -- ── BUTTONS ─────────────────────────────────────────
    for _, btn in ipairs(buttons) do
        drawButton(btn)
    end
end

local function selectPlayerByClick(x, y)
    local W, H = term.getSize()
    local top    = 4   -- HEADER_H + 1
    local leftW  = math.max(16, math.floor(W * 0.28))
    local BTN_H  = BUTTON_AREA_H
    local FOOT_H = 1
    local contentH = math.max(4, H - top - FOOT_H - BTN_H - 1)

    if x < 2 or x > leftW + 1 then return false end
    if y <= top or y >= top + contentH then return false end

    local index = y - top
    if state.players[index] then
        state.selectedIndex = index
        refreshLogs()
        setMessage("Selected " .. state.players[index].displayName, false)
        return true
    end

    return false
end

local function boot()
    math.randomseed(os.epoch("utc"))

    local opened = net.openWiredModems()
    if opened == 0 then
        error("No wired modem found. Attach at least one wired modem.")
    end

    rebuildButtons()
    refreshAll()

    while true do
        drawDashboard()

        local event, p1, p2, p3 = os.pullEvent()
        if event == "mouse_click" then
            local clickX = p2
            local clickY = p3

            if not selectPlayerByClick(clickX, clickY) then
                for _, button in ipairs(buttons) do
                    if inside(button, clickX, clickY) then
                        if button.key == "0" then
                            return
                        end
                        if button.action then
                            button.action()
                        end
                        break
                    end
                end
            end
        elseif event == "char" then
            local key = p1
            for _, button in ipairs(buttons) do
                if button.key == key then
                    if button.key == "0" then
                        return
                    end
                    if button.action then
                        button.action()
                    end
                    break
                end
            end
        elseif event == "term_resize" then
            rebuildButtons()
        end
    end
end

boot()
