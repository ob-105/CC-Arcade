local protocol = {}

protocol.PROTOCOL_REQ = "arcade.req.v1"
protocol.PROTOCOL_RESP_PREFIX = "arcade.resp.v1."

local requestCounter = 0

local function nowUtc()
    return os.epoch("utc")
end

local function nextRequestId(machineId)
    requestCounter = requestCounter + 1
    return table.concat({ machineId or "machine", tostring(nowUtc()), tostring(requestCounter) }, "-")
end

function protocol.responseProtocol(machineId)
    return protocol.PROTOCOL_RESP_PREFIX .. tostring(machineId)
end

function protocol.makeRequest(machineId, role, token, messageType, payload)
    return {
        requestId = nextRequestId(machineId),
        machineId = machineId,
        role = role,
        token = token,
        timestamp = nowUtc(),
        type = messageType,
        payload = payload or {},
    }
end

function protocol.makeResponse(requestId, ok, data, err)
    return {
        ok = ok,
        requestId = requestId,
        data = data,
        error = err,
        timestamp = nowUtc(),
    }
end

return protocol
