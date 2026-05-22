local protocol = dofile("/shared/protocol.lua")
local security = dofile("/shared/security.lua")
local net = dofile("/shared/net.lua")

local MACHINE_ID = "kiosk-01"
local ROLE = "kiosk"
local TOKEN_FILE = "/arcade_token.txt"

local config = {
    requestTimeout = 5,
    serverId = nil,
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

local function send(messageType, payload)
    local token = security.loadToken(TOKEN_FILE)
    local request = protocol.makeRequest(MACHINE_ID, ROLE, token, messageType, payload)
    local ok, response = net.sendRequest(config.serverId, request, config.requestTimeout)

    if not ok then
        return false, nil, "timeout"
    end

    if not response.ok then
        return false, nil, response.error
    end

    return true, response.data, nil
end

local function discoverServer()
    local token = security.loadToken(TOKEN_FILE)
    local serverId, err = net.discoverServer(MACHINE_ID, ROLE, token, 3)
    if not serverId then
        return false, err
    end

    config.serverId = serverId
    return true, nil
end

local function showByCard()
    local card = parseCardFile("/disk/arcade_card.txt")
    if not card then
        print("Insert a valid card disk in /disk")
        return
    end

    local ok, data, err = send("balance.get", { cardId = card.cardId })
    if not ok then
        print("Lookup failed: " .. tostring(err))
        return
    end

    print("Player: " .. data.displayName)
    print("Credits: " .. tostring(data.credits or 0))
    print("Tickets: " .. tostring(data.tickets))

    local txOk, txData = send("tx.listRecent", { playerId = data.playerId, limit = 5 })
    if txOk then
        print("")
        print("Recent activity:")
        for _, tx in ipairs(txData.items) do
            print(string.format("%s %d (%s)", tx.type, tx.amount, tx.note or "-"))
        end
    end
end

local function showByPlayerId()
    local playerId = ask("playerId: ")
    local ok, data, err = send("balance.get", { playerId = playerId })

    if not ok then
        print("Lookup failed: " .. tostring(err))
        return
    end

    print("Player: " .. data.displayName)
    print("Credits: " .. tostring(data.credits or 0))
    print("Tickets: " .. tostring(data.tickets))

    local txOk, txData = send("tx.listRecent", { playerId = data.playerId, limit = 5 })
    if txOk then
        print("")
        print("Recent activity:")
        for _, tx in ipairs(txData.items) do
            print(string.format("%s %d (%s)", tx.type, tx.amount, tx.note or "-"))
        end
    end
end

local function boot()
    local opened = net.openWiredModems()
    if opened == 0 then
        error("No wired modem found. Attach at least one wired modem.")
    end

    local ok, err = discoverServer()
    if not ok then
        error("Server discovery failed: " .. tostring(err))
    end

    while true do
        clear()
        print("Arcade Balance Checker")
        print("Machine: " .. MACHINE_ID)
        print(string.rep("-", 35))
        print("1) Read card in drive")
        print("2) Lookup by playerId")
        print("3) Rediscover server")
        print("0) Exit")

        local choice = ask("Select: ")
        clear()

        if choice == "1" then
            showByCard()
        elseif choice == "2" then
            showByPlayerId()
        elseif choice == "3" then
            local discoverOk, discoverErr = discoverServer()
            if discoverOk then
                print("Server found: " .. tostring(config.serverId))
            else
                print("Discovery failed: " .. tostring(discoverErr))
            end
        elseif choice == "0" then
            return
        else
            print("Unknown option")
        end

        print("")
        print("Press Enter to continue...")
        read()
    end
end

boot()
