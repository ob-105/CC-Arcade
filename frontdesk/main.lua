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

local ui = {
    message = "",
    isError = false,
    menuTop = 6,
}

local function clear()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
end

local function ask(prompt)
    write(prompt)
    return read()
end

local function clearAll(bg, fg)
    term.setBackgroundColor(bg or colors.black)
    term.setTextColor(fg or colors.white)
    term.clear()
    term.setCursorPos(1, 1)
end

local function fillRect(x, y, w, h, bg, fg)
    term.setBackgroundColor(bg)
    term.setTextColor(fg)
    for row = 0, h - 1 do
        term.setCursorPos(x, y + row)
        term.write(string.rep(" ", w))
    end
end

local function writeAt(x, y, text, bg, fg)
    if bg then
        term.setBackgroundColor(bg)
    end
    if fg then
        term.setTextColor(fg)
    end
    term.setCursorPos(x, y)
    term.write(text)
end

local function clampText(text, width)
    text = tostring(text or "")
    if #text <= width then
        return text
    end
    if width <= 3 then
        return string.sub(text, 1, width)
    end
    return string.sub(text, 1, width - 3) .. "..."
end

local function setMessage(message, isError)
    ui.message = message or ""
    ui.isError = isError == true
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

    if not card.cardId then
        return nil
    end

    return card
end

local function generateCardId()
    local n = math.random(0x10000000, 0xFFFFFFFF)
    local m = math.random(0x1000, 0xFFFF)
    return string.format("AC-%08X-%04X", n, m)
end

local function createPlayer()
    clear()
    print("Create Player")
    print(string.rep("-", 30))
    local displayName = ask("Display name: ")
    if displayName == "" then
        setMessage("Create cancelled", false)
        return
    end

    local ok, data, err = send("player.create", { displayName = displayName })
    if not ok then
        setMessage("Create failed: " .. tostring(err), true)
        return
    end

    setMessage("Created " .. data.player.displayName .. " as " .. data.player.playerId, false)
end

local function lookupPlayer()
    clear()
    print("Lookup Player")
    print(string.rep("-", 30))

    local mode = ask("Lookup by [1] playerId [2] card in drive [3] name: ")
    local payload = {}

    if mode == "1" then
        payload.playerId = ask("playerId: ")
        if payload.playerId == "" then
            setMessage("Lookup cancelled", false)
            return
        end
    elseif mode == "2" then
        local card = parseCardFile("/disk/arcade_card.txt")
        if not card then
            setMessage("No valid card file in /disk/arcade_card.txt", true)
            return
        end
        payload.cardId = card.cardId
    else
        payload.displayName = ask("displayName: ")
        if payload.displayName == "" then
            setMessage("Lookup cancelled", false)
            return
        end
    end

    local ok, data, err = send("player.lookup", payload)
    if not ok then
        setMessage("Lookup failed: " .. tostring(err), true)
        return
    end

    local p = data.player
    clear()
    print("Player Details")
    print(string.rep("-", 30))
    print("Name: " .. p.displayName)
    print("ID: " .. p.playerId)
    print("Card: " .. tostring(p.cardId))
    print("Tickets: disabled")
    print("")
    print("Press Enter to return")
    read()

    setMessage("Lookup complete for " .. p.displayName, false)
end

local function renamePlayer()
    clear()
    print("Rename Player")
    print(string.rep("-", 30))
    local playerId = ask("playerId: ")
    if playerId == "" then
        setMessage("Rename cancelled", false)
        return
    end

    local newName = ask("New display name: ")
    if newName == "" then
        setMessage("Rename cancelled", false)
        return
    end

    local ok, data, err = send("player.rename", {
        playerId = playerId,
        newDisplayName = newName,
    })

    if not ok then
        setMessage("Rename failed: " .. tostring(err), true)
        return
    end

    setMessage("Renamed to " .. data.player.displayName, false)
end

local function issueCard()
    if not fs.exists("/disk") then
        setMessage("No floppy disk detected in a disk drive", true)
        return
    end

    local cardId = generateCardId()
    local file = fs.open("/disk/arcade_card.txt", "w")
    if not file then
        setMessage("Failed to write /disk/arcade_card.txt", true)
        return
    end

    file.writeLine("cardId=" .. cardId)
    file.writeLine("version=1")
    file.writeLine("issuedAt=" .. tostring(os.epoch("utc")))
    file.close()

    disk.setLabel("Arcade Card " .. string.sub(cardId, -4))
    setMessage("Issued card: " .. cardId, false)
end

local function linkCard()
    clear()
    print("Link Card")
    print(string.rep("-", 30))
    local mode = ask("Link by [1] playerId [2] display name: ")
    local payload = {}

    if mode == "1" then
        payload.playerId = ask("playerId: ")
        if payload.playerId == "" then
            setMessage("Link cancelled", false)
            return
        end
    else
        payload.displayName = ask("displayName: ")
        if payload.displayName == "" then
            setMessage("Link cancelled", false)
            return
        end
    end

    local card = parseCardFile("/disk/arcade_card.txt")
    if not card then
        setMessage("No valid card file in /disk/arcade_card.txt", true)
        return
    end

    payload.cardId = card.cardId

    local ok, data, err = send("player.linkCard", payload)

    if not ok then
        setMessage("Link failed: " .. tostring(err), true)
        return
    end

    setMessage("Linked " .. data.player.displayName .. " to card " .. card.cardId, false)
end

local function listRecent()
    clear()
    print("Recent Transactions")
    print(string.rep("-", 30))
    local playerId = ask("playerId (leave blank for global): ")
    local limit = tonumber(ask("Limit (default 5): ")) or 5

    local payload = { limit = limit }
    if playerId ~= "" then
        payload.playerId = playerId
    end

    local ok, data, err = send("tx.listRecent", payload)
    if not ok then
        setMessage("Query failed: " .. tostring(err), true)
        return
    end

    clear()
    print("Recent transactions:")
    for _, tx in ipairs(data.items) do
        print(
            string.format(
                "%s | %s | %s | %d | bal %d | %s",
                tx.txId,
                tx.playerId,
                tx.type,
                tx.amount,
                tx.balanceAfter,
                tx.sourceMachineId
            )
        )
    end

    print("")
    print("Press Enter to return to dashboard")
    read()

    setMessage("Displayed " .. tostring(#data.items) .. " transactions", false)
end

local function rediscoverServerAction()
    config.serverId = nil
    requireServer()
end

local function inside(button, x, y)
    return x >= button.x and x <= (button.x + button.w - 1) and y >= button.y and y <= (button.y + button.h - 1)
end

local function drawButton(button)
    local fg = button.fg or colors.black
    local bg = button.bg or colors.lightGray
    term.setBackgroundColor(bg)
    term.setTextColor(fg)

    for row = 0, button.h - 1 do
        term.setCursorPos(button.x, button.y + row)
        term.write(string.rep(" ", button.w))
    end

    local label = clampText(button.label, button.w - 2)
    local labelX = button.x + math.floor((button.w - #label) / 2)
    local labelY = button.y + math.floor(button.h / 2)
    term.setCursorPos(labelX, labelY)
    term.write(label)
end

local function buildButtons()
    local width, h = term.getSize()
    local w = math.min(28, math.max(18, width - 8))
    local x = math.floor((width - w) / 2) + 1
    local y = ui.menuTop
    local bh = 2
    local gap = 1

    return {
        { key = "1", label = "Create Player", action = createPlayer, x = x, y = y + (bh + gap) * 0, w = w, h = bh, bg = colors.cyan },
        { key = "2", label = "Lookup Player", action = lookupPlayer, x = x, y = y + (bh + gap) * 1, w = w, h = bh, bg = colors.lightBlue },
        { key = "3", label = "Rename Player", action = renamePlayer, x = x, y = y + (bh + gap) * 2, w = w, h = bh, bg = colors.orange },
        { key = "4", label = "Issue Card", action = issueCard, x = x, y = y + (bh + gap) * 3, w = w, h = bh, bg = colors.yellow },
        { key = "5", label = "Link Card", action = linkCard, x = x, y = y + (bh + gap) * 4, w = w, h = bh, bg = colors.lime },
        { key = "6", label = "Recent Logs", action = listRecent, x = x, y = y + (bh + gap) * 5, w = w, h = bh, bg = colors.pink },
        { key = "7", label = "Rediscover", action = rediscoverServerAction, x = x, y = y + (bh + gap) * 6, w = w, h = bh, bg = colors.gray, fg = colors.white },
        { key = "0", label = "Exit", action = nil, x = x, y = h - 2, w = w, h = bh, bg = colors.red, fg = colors.white },
    }
end

local function drawDashboard(buttons)
    clearAll(colors.black, colors.white)
    local width, height = term.getSize()

    writeAt(math.max(1, math.floor((width - 17) / 2)), 2, "Arcade Front Desk", colors.black, colors.white)
    writeAt(2, 3, clampText("Machine: " .. MACHINE_ID, width - 2), colors.black, colors.lightGray)
    writeAt(2, 4, clampText("Server: " .. tostring(config.serverId), width - 2), colors.black, colors.lightGray)
    writeAt(2, 5, "Ticket mode: disabled", colors.black, colors.lightGray)

    for _, button in ipairs(buttons) do
        drawButton(button)
    end

    writeAt(2, height - 1, string.rep(" ", math.max(1, width - 2)), colors.black, colors.white)
    writeAt(2, height - 1, clampText(ui.message or "", width - 3), colors.black, ui.isError and colors.red or colors.lime)
end

local function boot()
    math.randomseed(os.epoch("utc"))

    local opened = net.openWiredModems()
    if opened == 0 then
        error("No wired modem found. Attach at least one wired modem.")
    end

    requireServer()

    local buttons = buildButtons()

    while true do
        drawDashboard(buttons)

        local event, p1, p2, p3 = os.pullEvent()
        if event == "mouse_click" then
            local clickX = p2
            local clickY = p3
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
        end
    end
end

boot()
