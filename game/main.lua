local protocol = dofile("/shared/protocol.lua")
local security = dofile("/shared/security.lua")
local net = dofile("/shared/net.lua")

local MACHINE_ID = "game-demo-racer-01"
local ROLE = "game"
local TOKEN_FILE = "/arcade_token.txt"

local GAME_ID = "demo_racer"

local config = {
    requestTimeout = 5,
    serverId = nil,
    backboneModemSide = "bottom",
    cabinetModemSide = "back",
    cardDriveSide = "top",
    cabinetChannel = 34001,
    cabinetReplyChannel = 34002,
    creditCostStart = 1,
    autoBuyEngineUpgrade = false,
    awardByScoreTier = {
        { minScore = 0, tickets = 0 },
        { minScore = 100, tickets = 5 },
        { minScore = 250, tickets = 10 },
        { minScore = 500, tickets = 20 },
    },
    maxAwardPerRound = 30,
}

local function clear()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
end

local lastStatus = ""

local function status(message)
    if message == lastStatus then
        return
    end

    lastStatus = message
    clear()
    print("Demo Racer Cabinet Client")
    print("Machine: " .. MACHINE_ID)
    print("Server: " .. tostring(config.serverId))
    print(string.rep("-", 38))
    print(message)
end

local function isWiredModemSide(side)
    if peripheral.getType(side) ~= "modem" then
        return false
    end

    local ok, wireless = pcall(peripheral.call, side, "isWireless")
    return ok and wireless == false
end

local function openBackboneRednet()
    local side = config.backboneModemSide
    if not isWiredModemSide(side) then
        error("Backbone modem side is not a wired modem: " .. tostring(side))
    end

    if not rednet.isOpen(side) then
        rednet.open(side)
    end
end

local function openCabinetModemChannels()
    local side = config.cabinetModemSide
    if not isWiredModemSide(side) then
        error("Cabinet modem side is not a wired modem: " .. tostring(side))
    end

    peripheral.call(side, "open", config.cabinetChannel)
    peripheral.call(side, "open", config.cabinetReplyChannel)
end

local function cabinetSend(message)
    local side = config.cabinetModemSide
    if not isWiredModemSide(side) then
        return false
    end

    peripheral.call(side, "transmit", config.cabinetChannel, config.cabinetReplyChannel, message)
    return true
end

local function getCardMountPath()
    local side = config.cardDriveSide
    if not disk.isPresent(side) or not disk.hasData(side) then
        return nil
    end

    return disk.getMountPath(side)
end

local function parseKeyValueFile(path)
    if not fs.exists(path) then
        return nil
    end

    local file = fs.open(path, "r")
    if not file then
        return nil
    end

    local data = {}
    while true do
        local line = file.readLine()
        if not line then
            break
        end

        local key, value = string.match(line, "^(%w+)%s*=%s*(.+)$")
        if key and value then
            data[key] = value
        end
    end

    file.close()
    return data
end

local function writeKeyValueFile(path, data)
    local dir = fs.getDir(path)
    if dir and dir ~= "" and not fs.exists(dir) then
        fs.makeDir(dir)
    end

    local file = fs.open(path, "w")
    if not file then
        return false
    end

    for key, value in pairs(data) do
        file.writeLine(key .. "=" .. tostring(value))
    end

    file.close()
    return true
end

local discoverServer

local function send(messageType, payload)
    local token = security.loadToken(TOKEN_FILE)
    local function sendOnce()
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

    local ok, data, err = sendOnce()
    if ok then
        return true, data, nil
    end

    local discovered, discoverErr = discoverServer()
    if not discovered then
        return false, nil, discoverErr or err
    end

    return sendOnce()
end

discoverServer = function()
    local token = security.loadToken(TOKEN_FILE)
    local serverId, err = net.discoverServer(MACHINE_ID, ROLE, token, 3)
    if not serverId then
        return false, err
    end

    config.serverId = serverId
    return true, nil
end

local function readCard()
    local mountPath = getCardMountPath()
    if not mountPath then
        return nil
    end

    local card = parseKeyValueFile(fs.combine(mountPath, "arcade_card.txt"))
    if not card or not card.cardId then
        return nil
    end

    card._mountPath = mountPath

    return card
end

local function loadSave(cardMountPath)
    local savePath = fs.combine(cardMountPath, "saves/" .. GAME_ID .. ".txt")
    local save = parseKeyValueFile(savePath)
    if not save then
        return {
            profileVersion = 1,
            engineLevel = 1,
            tireLevel = 1,
            armorLevel = 1,
            paint = "red",
            lastPlayedAt = 0,
        }
    end

    local function clampInt(v, low, high, fallback)
        local n = tonumber(v)
        if not n then
            return fallback
        end
        n = math.floor(n)
        if n < low then
            return low
        end
        if n > high then
            return high
        end
        return n
    end

    return {
        profileVersion = 1,
        engineLevel = clampInt(save.engineLevel, 1, 5, 1),
        tireLevel = clampInt(save.tireLevel, 1, 5, 1),
        armorLevel = clampInt(save.armorLevel, 1, 5, 1),
        paint = save.paint or "red",
        lastPlayedAt = clampInt(save.lastPlayedAt, 0, 9999999999999, 0),
    }
end

local function savePlayerData(cardMountPath, save)
    local savePath = fs.combine(cardMountPath, "saves/" .. GAME_ID .. ".txt")
    return writeKeyValueFile(savePath, save)
end

local function computeAward(score)
    local tickets = 0
    for _, tier in ipairs(config.awardByScoreTier) do
        if score >= tier.minScore then
            tickets = tier.tickets
        end
    end

    if tickets > config.maxAwardPerRound then
        tickets = config.maxAwardPerRound
    end

    return tickets
end

local function playRound(save)
    local base = math.random(80, 300)
    local bonus = (save.engineLevel + save.tireLevel + save.armorLevel) * math.random(5, 25)
    local score = base + bonus

    local upgradeBought = config.autoBuyEngineUpgrade and score > 450 and save.engineLevel < 5

    return {
        score = score,
        tickets = computeAward(score),
        engineUpgradeBought = upgradeBought,
    }
end

local function hasCard()
    return readCard() ~= nil
end

local function waitForCard()
    status("Idle: waiting for card in top drive")
    cabinetSend({ type = "client.idle_waiting_card", machineId = MACHINE_ID, gameId = GAME_ID })
    while true do
        local card = readCard()
        if card then
            return card
        end
        sleep(0.2)
    end
end

local function waitForCabinetStart(cardId)
    status("Card detected. Waiting cabinet start event on back modem")
    cabinetSend({
        type = "client.player_ready",
        machineId = MACHINE_ID,
        gameId = GAME_ID,
        cardId = cardId,
    })

    while true do
        if not hasCard() then
            return false, "CARD_REMOVED"
        end

        local event, side, channel, replyChannel, payload = os.pullEvent()
        if event == "modem_message" and side == config.cabinetModemSide then
            if channel == config.cabinetChannel or channel == config.cabinetReplyChannel then
                if type(payload) == "table" then
                    if payload.type == "cabinet.start_pressed" or payload.type == "start_pressed" then
                        return true, nil
                    end

                    if payload.type == "cabinet.ping" then
                        cabinetSend({
                            type = "client.pong",
                            machineId = MACHINE_ID,
                            gameId = GAME_ID,
                        })
                    end
                end
            end
        end
    end
end

local function runGameLoop()
    while true do
        local card = waitForCard()

        local lookupOk, playerData, lookupErr = send("player.lookup", { cardId = card.cardId })
        if not lookupOk then
            status("Card read but player lookup failed: " .. tostring(lookupErr))
            sleep(1)
        else
            local player = playerData.player
            local save = loadSave(card._mountPath)

            status("Player " .. player.displayName .. " ready. Awaiting cabinet start.")
            local startOk, startErr = waitForCabinetStart(card.cardId)
            if not startOk then
                status("Round cancelled: " .. tostring(startErr))
                sleep(0.5)
            else
                cabinetSend({
                    type = "client.round_starting",
                    machineId = MACHINE_ID,
                    gameId = GAME_ID,
                    playerId = player.playerId,
                    cardId = card.cardId,
                })

                local spendOk, spendData, spendErr = send("game.credit.take", {
                    playerId = player.playerId,
                    amount = config.creditCostStart,
                    note = "start_round",
                    gameId = GAME_ID,
                })

                if not spendOk then
                    status("Credit denied: " .. tostring(spendErr))
                    cabinetSend({
                        type = "client.round_denied",
                        machineId = MACHINE_ID,
                        gameId = GAME_ID,
                        reason = spendErr,
                    })
                    sleep(1)
                else
                    local result = playRound(save)

                    if result.engineUpgradeBought then
                        local upgradeOk = send("game.credit.take", {
                            playerId = player.playerId,
                            amount = 1,
                            note = "engine_upgrade",
                            gameId = GAME_ID,
                        })
                        if upgradeOk then
                            save.engineLevel = math.min(save.engineLevel + 1, 5)
                        end
                    end

                    if result.tickets > 0 then
                        send("game.ticket.award", {
                            playerId = player.playerId,
                            amount = result.tickets,
                            note = "round_complete",
                            score = result.score,
                            gameId = GAME_ID,
                        })
                    end

                    save.lastPlayedAt = os.epoch("utc")
                    savePlayerData(card._mountPath, save)

                    cabinetSend({
                        type = "client.round_complete",
                        machineId = MACHINE_ID,
                        gameId = GAME_ID,
                        playerId = player.playerId,
                        score = result.score,
                        tickets = result.tickets,
                    })

                    status("Round done for " .. player.displayName .. " | score " .. tostring(result.score) .. " | spend bal " .. tostring(spendData.balanceAfter))
                    sleep(1)
                end
            end
        end
    end
end

local function boot()
    math.randomseed(os.epoch("utc"))

    openBackboneRednet()
    openCabinetModemChannels()

    if peripheral.getType(config.cardDriveSide) ~= "drive" then
        error("Expected disk drive on side: " .. tostring(config.cardDriveSide))
    end

    local ok, err = discoverServer()
    if not ok then
        status("Initial server discovery failed: " .. tostring(err))
    end

    runGameLoop()
end

boot()
