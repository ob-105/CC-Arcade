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
        print("Server discovery failed: " .. tostring(err))
        return false
    end

    config.serverId = serverId
    print("Connected to server id " .. tostring(serverId))
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

local function issueCard()
    if not fs.exists("/disk") then
        print("No floppy disk detected in a disk drive.")
        return
    end

    local cardId = generateCardId()
    local file = fs.open("/disk/arcade_card.txt", "w")
    if not file then
        print("Failed to write /disk/arcade_card.txt")
        return
    end

    file.writeLine("cardId=" .. cardId)
    file.writeLine("version=1")
    file.writeLine("issuedAt=" .. tostring(os.epoch("utc")))
    file.close()

    disk.setLabel("Arcade Card " .. string.sub(cardId, -4))
    print("Issued card: " .. cardId)
end

local function lookupPlayer()
    local mode = ask("Lookup by [1] playerId [2] card in drive [3] name: ")
    local payload = {}

    if mode == "1" then
        payload.playerId = ask("playerId: ")
    elseif mode == "2" then
        local card = parseCardFile("/disk/arcade_card.txt")
        if not card then
            print("No valid card file in /disk/arcade_card.txt")
            return
        end
        payload.cardId = card.cardId
    else
        payload.displayName = ask("displayName: ")
    end

    local ok, data, err = send("player.lookup", payload)
    if not ok then
        print("Lookup failed: " .. tostring(err))
        return
    end

    local p = data.player
    print("Player: " .. p.displayName)
    print("playerId: " .. p.playerId)
    print("tickets: " .. tostring(p.tickets))
    print("cardId: " .. tostring(p.cardId))
end

local function createPlayer()
    local displayName = ask("Display name: ")
    local ok, data, err = send("player.create", { displayName = displayName })
    if not ok then
        print("Create failed: " .. tostring(err))
        return
    end

    print("Created " .. data.player.displayName .. " as " .. data.player.playerId)
end

local function renamePlayer()
    local playerId = ask("playerId: ")
    local newName = ask("New display name: ")

    local ok, data, err = send("player.rename", {
        playerId = playerId,
        newDisplayName = newName,
    })

    if not ok then
        print("Rename failed: " .. tostring(err))
        return
    end

    print("Renamed to " .. data.player.displayName)
end

local function linkCard()
    local mode = ask("Link by [1] playerId [2] display name: ")
    local payload = {}

    if mode == "1" then
        payload.playerId = ask("playerId: ")
    else
        payload.displayName = ask("displayName: ")
    end

    local card = parseCardFile("/disk/arcade_card.txt")
    if not card then
        print("No valid card file in /disk/arcade_card.txt")
        return
    end

    payload.cardId = card.cardId

    local ok, data, err = send("player.linkCard", payload)

    if not ok then
        print("Link failed: " .. tostring(err))
        return
    end

    print("Linked " .. data.player.displayName .. " to card " .. card.cardId)
end

local function adjustTickets(isAdd)
    local playerId = ask("playerId: ")
    local amount = tonumber(ask("Amount: "))

    if not security.isPositiveInt(amount) then
        print("Amount must be a positive whole number")
        return
    end

    local note = ask("Reason note: ")
    local messageType = isAdd and "tickets.add" or "tickets.spend"

    local ok, data, err = send(messageType, {
        playerId = playerId,
        amount = amount,
        note = note,
    })

    if not ok then
        print("Adjustment failed: " .. tostring(err))
        return
    end

    print("New balance: " .. tostring(data.balanceAfter))
end

local function listRecent()
    local playerId = ask("playerId (leave blank for global): ")
    local limit = tonumber(ask("Limit (default 5): ")) or 5

    local payload = { limit = limit }
    if playerId ~= "" then
        payload.playerId = playerId
    end

    local ok, data, err = send("tx.listRecent", payload)
    if not ok then
        print("Query failed: " .. tostring(err))
        return
    end

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
end

local function showMenu()
    print("Front Desk Admin Console")
    print("Machine: " .. MACHINE_ID .. " -> Server: " .. tostring(config.serverId))
    print(string.rep("-", 45))
    print("1) Create player")
    print("2) Lookup player")
    print("3) Rename player")
    print("4) Issue new card on disk")
    print("5) Link inserted card to player (name or id)")
    print("6) Add tickets")
    print("7) Remove tickets")
    print("8) View recent transactions")
    print("9) Rediscover server")
    print("0) Exit")
end

local function boot()
    math.randomseed(os.epoch("utc"))

    local opened = net.openWiredModems()
    if opened == 0 then
        error("No wired modem found. Attach at least one wired modem.")
    end

    if not requireServer() then
        return
    end

    while true do
        clear()
        showMenu()

        local choice = ask("Select: ")
        clear()

        if choice == "1" then
            createPlayer()
        elseif choice == "2" then
            lookupPlayer()
        elseif choice == "3" then
            renamePlayer()
        elseif choice == "4" then
            issueCard()
        elseif choice == "5" then
            linkCard()
        elseif choice == "6" then
            adjustTickets(true)
        elseif choice == "7" then
            adjustTickets(false)
        elseif choice == "8" then
            listRecent()
        elseif choice == "9" then
            config.serverId = nil
            requireServer()
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
