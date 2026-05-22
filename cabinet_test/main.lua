local CABINET_ID = "cabinet-test-01"
local GAME_ID = "demo_racer"

local config = {
    modemSide = "right",
    channel = 34001,
    replyChannel = 34002,
    startButtonSide = "front",
    startButtonActive = true,
    autoStartOnReady = false,
}

local state = {
    playerReady = false,
    lastPlayerId = nil,
    lastCardId = nil,
    lastMessage = "Booting...",
    roundCount = 0,
    startSent = 0,
}

local function clear()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
end

local function isWiredModem(side)
    if peripheral.getType(side) ~= "modem" then
        return false
    end

    local ok, wireless = pcall(peripheral.call, side, "isWireless")
    return ok and wireless == false
end

local function send(payload)
    peripheral.call(config.modemSide, "transmit", config.channel, config.replyChannel, payload)
end

local function draw()
    clear()
    print("Arcade Cabinet Test Game")
    print("Cabinet: " .. CABINET_ID)
    print("Game: " .. GAME_ID)
    print("Modem side/channel: " .. config.modemSide .. " / " .. tostring(config.channel))
    print(string.rep("-", 46))
    print("Player ready: " .. tostring(state.playerReady))
    print("PlayerId: " .. tostring(state.lastPlayerId))
    print("CardId: " .. tostring(state.lastCardId))
    print("Rounds complete: " .. tostring(state.roundCount))
    print("Start events sent: " .. tostring(state.startSent))
    print("")
    print("Last message:")
    print(state.lastMessage)
    print("")
    print("Controls:")
    print("s = send start_pressed")
    print("p = send cabinet ping")
    print("a = toggle auto start when player ready")
    print("q = quit")
    print("Hardware trigger: redstone on " .. config.startButtonSide)
end

local function sendStartPressed(reason)
    send({
        type = "cabinet.start_pressed",
        cabinetId = CABINET_ID,
        gameId = GAME_ID,
        reason = reason or "manual",
        timestamp = os.epoch("utc"),
    })
    state.startSent = state.startSent + 1
    state.lastMessage = "Sent cabinet.start_pressed (" .. tostring(reason or "manual") .. ")"
    draw()
end

local function sendPing()
    send({
        type = "cabinet.ping",
        cabinetId = CABINET_ID,
        gameId = GAME_ID,
        timestamp = os.epoch("utc"),
    })
    state.lastMessage = "Sent cabinet.ping"
    draw()
end

local function handleClientMessage(payload)
    if type(payload) ~= "table" then
        return
    end

    local messageType = tostring(payload.type or "unknown")

    if messageType == "client.player_ready" then
        state.playerReady = true
        state.lastPlayerId = payload.playerId
        state.lastCardId = payload.cardId
        state.lastMessage = "Client ready for player card: " .. tostring(payload.cardId)
        if config.autoStartOnReady then
            sendStartPressed("auto_start_on_ready")
        end
    elseif messageType == "client.round_starting" then
        state.lastMessage = "Round starting for player " .. tostring(payload.playerId)
    elseif messageType == "client.round_complete" then
        state.playerReady = false
        state.roundCount = state.roundCount + 1
        state.lastMessage = "Round complete | score " .. tostring(payload.score) .. " | tickets " .. tostring(payload.tickets)
    elseif messageType == "client.round_denied" then
        state.playerReady = false
        state.lastMessage = "Round denied: " .. tostring(payload.reason)
    elseif messageType == "client.idle_waiting_card" then
        state.playerReady = false
        state.lastPlayerId = nil
        state.lastCardId = nil
        state.lastMessage = "Client idle: waiting for card"
    elseif messageType == "client.pong" then
        state.lastMessage = "Client pong received"
    else
        state.lastMessage = "Client event: " .. messageType
    end

    draw()
end

local function boot()
    if not isWiredModem(config.modemSide) then
        error("Expected wired modem on side: " .. tostring(config.modemSide))
    end

    peripheral.call(config.modemSide, "open", config.channel)
    peripheral.call(config.modemSide, "open", config.replyChannel)

    send({
        type = "cabinet.register",
        cabinetId = CABINET_ID,
        gameId = GAME_ID,
        timestamp = os.epoch("utc"),
    })

    draw()

    while true do
        local event, p1, p2, p3, p4, p5 = os.pullEvent()

        if event == "char" then
            local ch = string.lower(p1)
            if ch == "s" then
                sendStartPressed("keyboard")
            elseif ch == "p" then
                sendPing()
            elseif ch == "a" then
                config.autoStartOnReady = not config.autoStartOnReady
                state.lastMessage = "Auto start on ready: " .. tostring(config.autoStartOnReady)
                draw()
            elseif ch == "q" then
                clear()
                print("Cabinet test game stopped.")
                return
            end
        elseif event == "redstone" then
            local active = redstone.getInput(config.startButtonSide) == config.startButtonActive
            if active then
                sendStartPressed("redstone_button")
                while redstone.getInput(config.startButtonSide) == config.startButtonActive do
                    sleep(0.05)
                end
            end
        elseif event == "modem_message" then
            local side = p1
            local channel = p2
            local replyChannel = p3
            local payload = p4

            if side == config.modemSide and (channel == config.channel or channel == config.replyChannel) then
                handleClientMessage(payload)
            end
        end
    end
end

boot()
