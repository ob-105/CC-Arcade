local protocol = dofile("/shared/protocol.lua")
local security = dofile("/shared/security.lua")
local net = dofile("/shared/net.lua")

local MACHINE_ID = "game-demo-racer-01"
local ROLE = "game"
local TOKEN_FILE = "/arcade_token.txt"

local GAME_ID = "demo_racer"
local SAVE_FILE = "/disk/saves/demo_racer.txt"

local config = {
    requestTimeout = 5,
    serverId = nil,
    creditCostStart = 1,
    startSignalSide = "back",
    startSignalActive = true,
    autoStartDelaySeconds = 0.25,
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
    local card = parseKeyValueFile("/disk/arcade_card.txt")
    if not card or not card.cardId then
        return nil
    end

    return card
end

local function loadSave()
    local save = parseKeyValueFile(SAVE_FILE)
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

local function savePlayerData(save)
    return writeKeyValueFile(SAVE_FILE, save)
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
    status("Idle: waiting for player card disk")
    while true do
        local card = readCard()
        if card then
            return card
        end
        sleep(0.2)
    end
end

local function waitForStartSignal()
    if not config.startSignalSide or config.startSignalSide == "" then
        sleep(config.autoStartDelaySeconds)
        return true, nil
    end

    status("Card detected. Waiting start signal on " .. config.startSignalSide)

    while true do
        if not hasCard() then
            return false, "CARD_REMOVED"
        end

        local active = redstone.getInput(config.startSignalSide) == config.startSignalActive
        if active then
            while redstone.getInput(config.startSignalSide) == config.startSignalActive do
                sleep(0.05)
            end
            return true, nil
        end

        sleep(0.05)
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
            local save = loadSave()

            status("Player " .. player.displayName .. " ready. Awaiting start signal.")
            local startOk, startErr = waitForStartSignal()
            if not startOk then
                status("Round cancelled: " .. tostring(startErr))
                sleep(0.5)
            else
                local spendOk, spendData, spendErr = send("game.credit.take", {
                    playerId = player.playerId,
                    amount = config.creditCostStart,
                    note = "start_round",
                    gameId = GAME_ID,
                })

                if not spendOk then
                    status("Credit denied: " .. tostring(spendErr))
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
                    savePlayerData(save)

                    status("Round done for " .. player.displayName .. " | score " .. tostring(result.score) .. " | spend bal " .. tostring(spendData.balanceAfter))
                    sleep(1)
                end
            end
        end
    end
end

local function boot()
    math.randomseed(os.epoch("utc"))

    local opened = net.openWiredModems()
    if opened == 0 then
        error("No wired modem found. Attach at least one wired modem.")
    end

    local ok, err = discoverServer()
    if not ok then
        status("Initial server discovery failed: " .. tostring(err))
    end

    runGameLoop()
end

boot()
