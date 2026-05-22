local security = {}

security.DEFAULT_TOKEN = "change-me-in-arcade_token.txt"

local rolePermissions = {
    admin = {
        ["auth.login"] = true,
        ["player.lookup"] = true,
        ["player.list"] = true,
        ["player.create"] = true,
        ["player.rename"] = true,
        ["player.linkCard"] = true,
        ["balance.get"] = true,
        ["tickets.add"] = true,
        ["tickets.spend"] = true,
        ["tickets.award"] = true,
        ["tx.listRecent"] = true,
        ["ping"] = true,
    },
    kiosk = {
        ["player.lookup"] = true,
        ["balance.get"] = true,
        ["tx.listRecent"] = true,
        ["ping"] = true,
    },
    game = {
        ["player.lookup"] = true,
        ["balance.get"] = true,
        ["tickets.spend"] = true,
        ["tickets.award"] = true,
        ["game.credit.take"] = true,
        ["game.ticket.award"] = true,
        ["tx.listRecent"] = true,
        ["ping"] = true,
    },
    server = {
        ["ping"] = true,
    },
}

function security.loadToken(tokenFilePath)
    local path = tokenFilePath or "/arcade_token.txt"
    if not fs.exists(path) then
        return security.DEFAULT_TOKEN
    end

    local file = fs.open(path, "r")
    if not file then
        return security.DEFAULT_TOKEN
    end

    local token = file.readAll() or ""
    file.close()

    token = string.gsub(token, "^%s+", "")
    token = string.gsub(token, "%s+$", "")

    if token == "" then
        return security.DEFAULT_TOKEN
    end

    return token
end

function security.canRole(role, messageType)
    local roleMap = rolePermissions[role]
    if not roleMap then
        return false
    end

    return roleMap[messageType] == true
end

function security.validateToken(expectedToken, providedToken)
    return expectedToken == providedToken
end

function security.isPositiveInt(value)
    return type(value) == "number" and value > 0 and value == math.floor(value)
end

return security
