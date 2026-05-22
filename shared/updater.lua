local REPO_RAW_BASE = "https://raw.githubusercontent.com/ob-105/CC-Arcade/main/"
local ROLE_FILE = "/arcade_role.txt"

local sharedFiles = {
    "shared/protocol.lua",
    "shared/security.lua",
    "shared/net.lua",
    "shared/updater.lua",
}

local roleFiles = {
    server = {
        "server/main.lua",
        "arcade_token.example.txt",
    },
    frontdesk = {
        "frontdesk/main.lua",
        "arcade_token.example.txt",
    },
    kiosk = {
        "kiosk/main.lua",
        "arcade_token.example.txt",
    },
    game = {
        "game/main.lua",
        "arcade_token.example.txt",
    },
    cabinet_test = {
        "cabinet_test/main.lua",
    },
}

local function trim(value)
    if not value then
        return ""
    end

    value = string.gsub(value, "^%s+", "")
    value = string.gsub(value, "%s+$", "")
    return value
end

local function readRole()
    if not fs.exists(ROLE_FILE) then
        return nil
    end

    local file = fs.open(ROLE_FILE, "r")
    if not file then
        return nil
    end

    local text = trim(file.readAll())
    file.close()

    if text == "" then
        return nil
    end

    return text
end

local function ensureDir(path)
    local dir = fs.getDir(path)
    if dir and dir ~= "" and not fs.exists(dir) then
        fs.makeDir(dir)
    end
end

local function downloadToFile(relativePath)
    local url = REPO_RAW_BASE .. relativePath
    local response, err = http.get(url)
    if not response then
        return false, "GET failed for " .. relativePath .. " (" .. tostring(err) .. ")"
    end

    local body = response.readAll()
    response.close()

    if not body then
        return false, "Empty response for " .. relativePath
    end

    local outputPath = "/" .. relativePath
    ensureDir(outputPath)

    local file = fs.open(outputPath, "w")
    if not file then
        return false, "Write failed for " .. outputPath
    end

    file.write(body)
    file.close()

    return true, nil
end

local function buildUpdateList(role)
    local files = {}

    for _, path in ipairs(sharedFiles) do
        table.insert(files, path)
    end

    if roleFiles[role] then
        for _, path in ipairs(roleFiles[role]) do
            table.insert(files, path)
        end
    end

    return files
end

local function runUpdate()
    if not http then
        return false, "HTTP API unavailable"
    end

    local role = readRole()
    if not role then
        return false, "Missing /arcade_role.txt"
    end

    if not roleFiles[role] then
        return false, "Unknown role in /arcade_role.txt: " .. tostring(role)
    end

    local files = buildUpdateList(role)
    local okCount = 0
    local failCount = 0

    for _, path in ipairs(files) do
        local ok, err = downloadToFile(path)
        if ok then
            okCount = okCount + 1
        else
            failCount = failCount + 1
            print("[updater] " .. tostring(err))
        end
    end

    if failCount == 0 then
        print("[updater] updated " .. tostring(okCount) .. " files for role " .. role)
        return true, nil
    end

    return false, "updated " .. tostring(okCount) .. ", failed " .. tostring(failCount)
end

if ... == "--run" then
    local ok, err = runUpdate()
    if not ok and err then
        print("[updater] " .. err)
    end
end

return {
    runUpdate = runUpdate,
}
