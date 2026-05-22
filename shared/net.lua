local net = {}

local protocol = dofile("/shared/protocol.lua")

local function isWiredModem(side)
    if peripheral.getType(side) ~= "modem" then
        return false
    end

    local ok, wireless = pcall(peripheral.call, side, "isWireless")
    if not ok then
        return false
    end

    return wireless == false
end

function net.openWiredModems()
    local opened = 0
    for _, side in ipairs(peripheral.getNames()) do
        if isWiredModem(side) then
            if not rednet.isOpen(side) then
                rednet.open(side)
            end
            opened = opened + 1
        end
    end
    return opened
end

function net.waitForResponse(machineId, requestId, timeoutSeconds)
    local responseProtocol = protocol.responseProtocol(machineId)
    local deadline = os.clock() + (timeoutSeconds or 5)

    while os.clock() < deadline do
        local remaining = deadline - os.clock()
        local senderId, response = rednet.receive(responseProtocol, remaining)

        if senderId and type(response) == "table" and response.requestId == requestId then
            return true, response, senderId
        end
    end

    return false, nil, nil
end

function net.sendRequest(serverId, request, timeoutSeconds)
    rednet.send(serverId, request, protocol.PROTOCOL_REQ)
    local ok, response, responderId = net.waitForResponse(request.machineId, request.requestId, timeoutSeconds)
    if not ok then
        return false, nil, "timeout"
    end

    return true, response, responderId
end

function net.discoverServer(machineId, role, token, timeoutSeconds)
    local pingRequest = protocol.makeRequest(machineId, role, token, "ping", { discover = true })
    rednet.broadcast(pingRequest, protocol.PROTOCOL_REQ)

    local ok, response, responderId = net.waitForResponse(machineId, pingRequest.requestId, timeoutSeconds or 3)
    if not ok then
        return nil, "No server response"
    end

    if not response.ok then
        return nil, response.error or "Server rejected ping"
    end

    return responderId, nil
end

return net
