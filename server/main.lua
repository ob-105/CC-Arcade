local protocol = dofile("/shared/protocol.lua")
local security = dofile("/shared/security.lua")
local net = dofile("/shared/net.lua")

local SERVER_MACHINE_ID = "server-main-01"
local TOKEN_FILE = "/arcade_token.txt"
local PLAYERS_DB_PATH = "/server/db/players.db"
local TX_DB_PATH = "/server/db/transactions.db"
local ALLOWLIST_PATH = "/server/db/allowlist.db"

local state = {
    playersById = {},
    transactions = {},
    cardIndex = {},
    allowlist = {},
    recentLog = {},
}

local function ensureDir(path)
    if not fs.exists(path) then
        fs.makeDir(path)
    end
end

local function saveTable(path, value)
    local file = fs.open(path, "w")
    if not file then
        return false, "Failed to open " .. path .. " for write"
    end

    file.write(textutils.serialize(value))
    file.close()
    return true
end

local function loadTable(path, defaultValue)
    if not fs.exists(path) then
        return defaultValue
    end

    local file = fs.open(path, "r")
    if not file then
        return defaultValue
    end

    local text = file.readAll()
    file.close()

    if not text or text == "" then
        return defaultValue
    end

    local parsed = textutils.unserialize(text)
    if type(parsed) ~= "table" then
        return defaultValue
    end

    return parsed
end

local function pushLog(line)
    table.insert(state.recentLog, 1, os.date("%H:%M:%S") .. " " .. line)
    while #state.recentLog > 8 do
        table.remove(state.recentLog)
    end
end

local function rebuildCardIndex()
    state.cardIndex = {}
    for playerId, player in pairs(state.playersById) do
        if player.cardId and player.cardId ~= "" then
            state.cardIndex[player.cardId] = playerId
        end
    end
end

local function persistPlayers()
    return saveTable(PLAYERS_DB_PATH, state.playersById)
end

local function persistTx()
    return saveTable(TX_DB_PATH, state.transactions)
end

local function txId()
    return "tx-" .. tostring(os.epoch("utc")) .. "-" .. tostring(math.random(1000, 9999))
end

local function makePlayerId()
    return "player-" .. tostring(os.epoch("utc")) .. "-" .. tostring(math.random(100, 999))
end

local function getPlayer(payload)
    if not payload then
        return nil
    end

    if payload.playerId and state.playersById[payload.playerId] then
        return state.playersById[payload.playerId]
    end

    if payload.cardId and state.cardIndex[payload.cardId] then
        local playerId = state.cardIndex[payload.cardId]
        return state.playersById[playerId]
    end

    if payload.displayName then
        local targetName = string.lower(payload.displayName)
        for _, player in pairs(state.playersById) do
            if string.lower(player.displayName) == targetName then
                return player
            end
        end
    end

    return nil
end

local function addTransaction(playerId, txType, amount, balanceAfter, sourceMachineId, sourceRole, note)
    local tx = {
        txId = txId(),
        playerId = playerId,
        type = txType,
        amount = amount,
        balanceAfter = balanceAfter,
        sourceMachineId = sourceMachineId,
        sourceRole = sourceRole,
        note = note,
        timestamp = os.epoch("utc"),
    }

    table.insert(state.transactions, tx)
    if #state.transactions > 5000 then
        table.remove(state.transactions, 1)
    end

    persistTx()
    return tx
end

local function listRecentTransactions(playerId, limit)
    local items = {}
    local maxItems = math.max(1, math.min(limit or 5, 20))

    for i = #state.transactions, 1, -1 do
        local tx = state.transactions[i]
        if not playerId or tx.playerId == playerId then
            table.insert(items, tx)
        end

        if #items >= maxItems then
            break
        end
    end

    return items
end

local function validateRequest(request, expectedToken)
    if type(request) ~= "table" then
        return false, "BAD_REQUEST"
    end

    if type(request.requestId) ~= "string" or request.requestId == "" then
        return false, "BAD_REQUEST_ID"
    end

    if type(request.machineId) ~= "string" or request.machineId == "" then
        return false, "BAD_MACHINE_ID"
    end

    if type(request.role) ~= "string" or request.role == "" then
        return false, "BAD_ROLE"
    end

    if not security.validateToken(expectedToken, request.token) then
        return false, "BAD_TOKEN"
    end

    if not security.canRole(request.role, request.type) then
        return false, "ROLE_FORBIDDEN"
    end

    return true, nil
end

local function canUseMachine(machineId)
    if next(state.allowlist) == nil then
        return true
    end

    return state.allowlist[machineId] == true
end

local function handlePlayerCreate(request)
    local payload = request.payload or {}
    local displayName = payload.displayName

    if type(displayName) ~= "string" or displayName == "" then
        return false, nil, "INVALID_DISPLAY_NAME"
    end

    local playerId = payload.playerId
    if type(playerId) ~= "string" or playerId == "" then
        playerId = makePlayerId()
    end

    if state.playersById[playerId] then
        return false, nil, "PLAYER_EXISTS"
    end

    local now = os.epoch("utc")
    local player = {
        playerId = playerId,
        displayName = displayName,
        tickets = 0,
        createdAt = now,
        updatedAt = now,
        cardId = nil,
    }

    state.playersById[playerId] = player
    persistPlayers()
    addTransaction(playerId, "create", 0, player.tickets, request.machineId, request.role, "player_create")

    pushLog("Created player " .. displayName .. " (" .. playerId .. ")")
    return true, { player = player }
end

local function handlePlayerLookup(request)
    local player = getPlayer(request.payload)
    if not player then
        return false, nil, "PLAYER_NOT_FOUND"
    end

    return true, { player = player }
end

local function handlePlayerRename(request)
    local payload = request.payload or {}
    local player = getPlayer(payload)
    if not player then
        return false, nil, "PLAYER_NOT_FOUND"
    end

    if type(payload.newDisplayName) ~= "string" or payload.newDisplayName == "" then
        return false, nil, "INVALID_DISPLAY_NAME"
    end

    player.displayName = payload.newDisplayName
    player.updatedAt = os.epoch("utc")

    persistPlayers()
    addTransaction(player.playerId, "rename", 0, player.tickets, request.machineId, request.role, payload.newDisplayName)
    pushLog("Renamed " .. player.playerId .. " to " .. player.displayName)

    return true, { player = player }
end

local function handleLinkCard(request)
    local payload = request.payload or {}
    local player = getPlayer(payload)
    if not player then
        return false, nil, "PLAYER_NOT_FOUND"
    end

    if type(payload.cardId) ~= "string" or payload.cardId == "" then
        return false, nil, "INVALID_CARD"
    end

    local existing = state.cardIndex[payload.cardId]
    if existing and existing ~= player.playerId then
        return false, nil, "CARD_ALREADY_LINKED"
    end

    if player.cardId and player.cardId ~= "" then
        state.cardIndex[player.cardId] = nil
    end

    player.cardId = payload.cardId
    player.updatedAt = os.epoch("utc")
    state.cardIndex[payload.cardId] = player.playerId

    persistPlayers()
    addTransaction(player.playerId, "link_card", 0, player.tickets, request.machineId, request.role, payload.cardId)
    pushLog("Linked card " .. payload.cardId .. " -> " .. player.playerId)

    return true, { player = player }
end

local function applyTicketChange(request, txType, signedAmount)
    local payload = request.payload or {}
    local player = getPlayer(payload)
    if not player then
        return false, nil, "PLAYER_NOT_FOUND"
    end

    if not security.isPositiveInt(payload.amount) then
        return false, nil, "INVALID_AMOUNT"
    end

    local amount = payload.amount * signedAmount
    local newBalance = player.tickets + amount
    if newBalance < 0 then
        return false, nil, "INSUFFICIENT_TICKETS"
    end

    player.tickets = newBalance
    player.updatedAt = os.epoch("utc")
    persistPlayers()

    local txAmount = amount
    addTransaction(player.playerId, txType, txAmount, newBalance, request.machineId, request.role, payload.note)
    pushLog(txType .. " " .. tostring(txAmount) .. " for " .. player.playerId .. " -> " .. tostring(newBalance))

    return true, {
        playerId = player.playerId,
        balanceAfter = newBalance,
    }
end

local function handleListRecent(request)
    local payload = request.payload or {}
    local playerId = payload.playerId
    local limit = payload.limit or 5

    if playerId and not state.playersById[playerId] then
        return false, nil, "PLAYER_NOT_FOUND"
    end

    return true, {
        items = listRecentTransactions(playerId, limit),
    }
end

local function handleMessage(request)
    if request.type == "ping" then
        return true, {
            machineId = SERVER_MACHINE_ID,
            status = "online",
            players = tonumber((function()
                local count = 0
                for _ in pairs(state.playersById) do
                    count = count + 1
                end
                return count
            end)()),
        }
    end

    if request.type == "player.create" then
        return handlePlayerCreate(request)
    end

    if request.type == "player.lookup" then
        return handlePlayerLookup(request)
    end

    if request.type == "player.rename" then
        return handlePlayerRename(request)
    end

    if request.type == "player.linkCard" then
        return handleLinkCard(request)
    end

    if request.type == "balance.get" then
        local ok, data, err = handlePlayerLookup(request)
        if not ok then
            return false, nil, err
        end
        return true, {
            playerId = data.player.playerId,
            displayName = data.player.displayName,
            tickets = data.player.tickets,
            cardId = data.player.cardId,
        }
    end

    if request.type == "tickets.add" then
        return applyTicketChange(request, "adjust", 1)
    end

    if request.type == "tickets.award" or request.type == "game.ticket.award" then
        return applyTicketChange(request, "award", 1)
    end

    if request.type == "tickets.spend" or request.type == "game.credit.take" then
        return applyTicketChange(request, "spend", -1)
    end

    if request.type == "tx.listRecent" then
        return handleListRecent(request)
    end

    return false, nil, "UNSUPPORTED_TYPE"
end

local function drawUi()
    term.setCursorBlink(false)
    while true do
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.white)
        term.clear()
        term.setCursorPos(1, 1)

        local playerCount = 0
        for _ in pairs(state.playersById) do
            playerCount = playerCount + 1
        end

        print("Arcade Server | " .. SERVER_MACHINE_ID)
        print("Status: ONLINE  Players: " .. tostring(playerCount) .. "  Tx: " .. tostring(#state.transactions))
        print("Token file: " .. TOKEN_FILE)
        print(string.rep("-", 50))
        print("Recent events:")

        if #state.recentLog == 0 then
            print("(no events yet)")
        else
            for i = 1, #state.recentLog do
                print(state.recentLog[i])
            end
        end

        sleep(1)
    end
end

local function runServerLoop()
    local token = security.loadToken(TOKEN_FILE)

    while true do
        local senderId, request = rednet.receive(protocol.PROTOCOL_REQ)

        if senderId and type(request) == "table" then
            local responseProtocol = protocol.responseProtocol(request.machineId or "unknown")

            if not canUseMachine(request.machineId) then
                rednet.send(senderId, protocol.makeResponse(request.requestId or "unknown", false, nil, "MACHINE_NOT_ALLOWED"), responseProtocol)
            else
                local valid, err = validateRequest(request, token)
                if not valid then
                    rednet.send(senderId, protocol.makeResponse(request.requestId, false, nil, err), responseProtocol)
                    pushLog("Rejected " .. tostring(request.type) .. " from " .. tostring(request.machineId) .. " (" .. tostring(err) .. ")")
                else
                    local ok, data, handleErr = handleMessage(request)
                    rednet.send(senderId, protocol.makeResponse(request.requestId, ok, data, handleErr), responseProtocol)
                    if request.type ~= "ping" then
                        pushLog(request.type .. " from " .. request.machineId .. " -> " .. (ok and "ok" or (handleErr or "error")))
                    end
                end
            end
        end
    end
end

local function boot()
    math.randomseed(os.epoch("utc"))

    ensureDir("/server")
    ensureDir("/server/db")

    state.playersById = loadTable(PLAYERS_DB_PATH, {})
    state.transactions = loadTable(TX_DB_PATH, {})
    state.allowlist = loadTable(ALLOWLIST_PATH, {})
    rebuildCardIndex()

    local opened = net.openWiredModems()
    if opened == 0 then
        error("No wired modem found. Attach at least one wired modem.")
    end

    pushLog("Server started. Wired modem count: " .. tostring(opened))

    parallel.waitForAny(runServerLoop, drawUi)
end

boot()
