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

local function ask(prompt)
    write(prompt)
    return read()
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

local function discoverServer()
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

    local upgradeBought = false
    if score > 450 and save.engineLevel < 5 then
        local ok = ask("Buy engine upgrade for 1 credit? [y/N] ")
        if string.lower(ok) == "y" then
            upgradeBought = true
        end
    end

    return {
        score = score,
        tickets = computeAward(score),
        engineUpgradeBought = upgradeBought,
    }
end

local function runGameLoop()
    while true do
        clear()
        print("Demo Racer Cabinet")
        print("Machine: " .. MACHINE_ID)
        print("Insert card disk and press Enter.")
        read()

        local card = readCard()
        if not card then
            print("No valid card found at /disk/arcade_card.txt")
            print("Press Enter to try again")
            read()
        else
            local ok, playerData, err = send("player.lookup", { cardId = card.cardId })
            if not ok then
                print("Player lookup failed: " .. tostring(err))
                print("Press Enter to try again")
                read()
            else
                local player = playerData.player
                local save = loadSave()

                clear()
                print("Welcome " .. player.displayName)
                print("Tickets: " .. tostring(player.tickets))
                print("Engine level: " .. tostring(save.engineLevel))
                print("Press Enter to start round (cost " .. tostring(config.creditCostStart) .. " credit)")
                read()

                local spendOk, spendData, spendErr = send("game.credit.take", {
                    playerId = player.playerId,
                    amount = config.creditCostStart,
                    note = "start_round",
                    gameId = GAME_ID,
                })

                if not spendOk then
                    print("Credit denied: " .. tostring(spendErr))
                    print("Press Enter")
                    read()
                else
                    local result = playRound(save)
                    print("Round score: " .. tostring(result.score))
                    print("Tickets earned: " .. tostring(result.tickets))

                    if result.engineUpgradeBought then
                        local upgradeOk = send("game.credit.take", {
                            playerId = player.playerId,
                            amount = 1,
                            note = "engine_upgrade",
                            gameId = GAME_ID,
                        })
                        if upgradeOk then
                            save.engineLevel = math.min(save.engineLevel + 1, 5)
                            print("Engine upgraded to level " .. tostring(save.engineLevel))
                        else
                            print("Upgrade skipped due to credits")
                        end
                    end

                    if result.tickets > 0 then
                        local awardOk, awardData, awardErr = send("game.ticket.award", {
                            playerId = player.playerId,
                            amount = result.tickets,
                            note = "round_complete",
                            score = result.score,
                            gameId = GAME_ID,
                        })

                        if awardOk then
                            print("Awarded. New balance: " .. tostring(awardData.balanceAfter))
                        else
                            print("Award failed: " .. tostring(awardErr))
                        end
                    end

                    save.lastPlayedAt = os.epoch("utc")
                    savePlayerData(save)

                    print("Spent start credit. Balance after spend: " .. tostring(spendData.balanceAfter))
                    print("Press Enter for next player")
                    read()
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
        error("Server discovery failed: " .. tostring(err))
    end

    runGameLoop()
end

boot()
