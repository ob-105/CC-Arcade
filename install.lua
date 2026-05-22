local INSTALLER_TITLE = "CC Arcade Installer"
local REPO_RAW_BASE = "https://raw.githubusercontent.com/ob-105/CC-Arcade/main/"

local sharedFiles = {
    "shared/protocol.lua",
    "shared/security.lua",
    "shared/net.lua",
    "shared/updater.lua",
}

local roles = {
    {
        key = "1",
        id = "server",
        name = "Central Server",
        startupProgram = "/server/main.lua",
        roleFiles = {
            "server/main.lua",
            "arcade_token.example.txt",
        },
    },
    {
        key = "2",
        id = "frontdesk",
        name = "Front Desk Admin",
        startupProgram = "/frontdesk/main.lua",
        roleFiles = {
            "frontdesk/main.lua",
            "arcade_token.example.txt",
        },
    },
    {
        key = "3",
        id = "kiosk",
        name = "Balance Checker Kiosk",
        startupProgram = "/kiosk/main.lua",
        roleFiles = {
            "kiosk/main.lua",
            "arcade_token.example.txt",
        },
    },
    {
        key = "4",
        id = "game",
        name = "Game Cabinet Client",
        startupProgram = "/game/main.lua",
        roleFiles = {
            "game/main.lua",
            "arcade_token.example.txt",
        },
    },
}

local function clear()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
end

local function getSourceRoot()
    local running = shell.getRunningProgram() or "install.lua"
    local dir = fs.getDir(running)
    if dir == "" then
        return "/"
    end
    return fs.combine("/", dir)
end

local function listDir(path)
    if not fs.exists(path) or not fs.isDir(path) then
        return {}
    end
    return fs.list(path)
end

local function ensureDir(path)
    if path and path ~= "" and not fs.exists(path) then
        fs.makeDir(path)
    end
end

local function ensureParentDir(path)
    local dir = fs.getDir(path)
    ensureDir(dir)
end

local function nextBackupPath(basePath)
    if not fs.exists(basePath) then
        return basePath
    end

    local n = 1
    while fs.exists(basePath .. "." .. tostring(n)) do
        n = n + 1
    end

    return basePath .. "." .. tostring(n)
end

local function combineFiles(role)
    local files = {}

    for _, path in ipairs(sharedFiles) do
        table.insert(files, path)
    end

    for _, path in ipairs(role.roleFiles) do
        table.insert(files, path)
    end

    return files
end

local function hasLocalSources(sourceRoot, files)
    for _, relative in ipairs(files) do
        if not fs.exists(fs.combine(sourceRoot, relative)) then
            return false
        end
    end
    return true
end

local function installFileFromLocal(sourceRoot, relativePath, overwrite)
    local srcPath = fs.combine(sourceRoot, relativePath)
    local dstPath = "/" .. relativePath

    if not fs.exists(srcPath) then
        return false, false, "Missing source: " .. srcPath
    end

    if fs.exists(dstPath) and not overwrite then
        return true, true, nil
    end

    if fs.exists(dstPath) and overwrite then
        fs.delete(dstPath)
    end

    ensureParentDir(dstPath)

    local ok, err = pcall(fs.copy, srcPath, dstPath)
    if not ok then
        return false, false, "Copy failed: " .. srcPath .. " -> " .. dstPath .. " (" .. tostring(err) .. ")"
    end

    return true, false, nil
end

local function installFileFromRemote(relativePath, overwrite)
    if not http then
        return false, false, "HTTP API unavailable"
    end

    local dstPath = "/" .. relativePath
    if fs.exists(dstPath) and not overwrite then
        return true, true, nil
    end

    local url = REPO_RAW_BASE .. relativePath
    local response, err = http.get(url)
    if not response then
        return false, false, "Download failed: " .. relativePath .. " (" .. tostring(err) .. ")"
    end

    local body = response.readAll()
    response.close()
    if not body or body == "" then
        return false, false, "Empty download: " .. relativePath
    end

    if fs.exists(dstPath) and overwrite then
        fs.delete(dstPath)
    end

    ensureParentDir(dstPath)

    local file = fs.open(dstPath, "w")
    if not file then
        return false, false, "Write failed: " .. dstPath
    end

    file.write(body)
    file.close()
    return true, false, nil
end

local function writeTokenIfMissing()
    if fs.exists("/arcade_token.txt") then
        return false
    end

    local file = fs.open("/arcade_token.txt", "w")
    if not file then
        return false
    end

    file.writeLine("change-me-shared-token")
    file.close()
    return true
end

local function writeRoleFile(roleId)
    local file = fs.open("/arcade_role.txt", "w")
    if not file then
        return false
    end

    file.writeLine(roleId)
    file.close()
    return true
end

local function writeStartup(programPath)
    local startupPath = "/startup"

    if fs.exists(startupPath) then
        local backup = nextBackupPath("/startup.backup")
        fs.move(startupPath, backup)
        print("Backed up existing startup to " .. backup)
    end

    local file = fs.open(startupPath, "w")
    if not file then
        return false, "Could not write /startup"
    end

    file.writeLine("local ok, updater = pcall(dofile, \"/shared/updater.lua\")")
    file.writeLine("if ok and updater and updater.runUpdate then")
    file.writeLine("  local updateOk = pcall(updater.runUpdate)")
    file.writeLine("  if not updateOk then")
    file.writeLine("    print(\"[startup] updater runtime error\")")
    file.writeLine("    sleep(1)")
    file.writeLine("  end")
    file.writeLine("else")
    file.writeLine("  print(\"[startup] updater not available\")")
    file.writeLine("  sleep(1)")
    file.writeLine("end")
    file.writeLine("shell.run(\"" .. programPath .. "\")")
    file.close()

    return true, nil
end

local function chooseRole()
    print(INSTALLER_TITLE)
    print(string.rep("-", 40))
    print("Select this computer's role:")

    for _, role in ipairs(roles) do
        print(role.key .. ") " .. role.name)
    end

    write("Choice: ")
    local choice = read()

    for _, role in ipairs(roles) do
        if role.key == choice then
            return role
        end
    end

    return nil
end

local function confirm(prompt, defaultYes)
    if defaultYes then
        write(prompt .. " [Y/n]: ")
    else
        write(prompt .. " [y/N]: ")
    end

    local answer = string.lower(read() or "")
    if answer == "" then
        return defaultYes
    end

    return answer == "y" or answer == "yes"
end

local function runInstall()
    clear()

    local role = chooseRole()
    if not role then
        print("Invalid selection.")
        return
    end

    print("")
    print("Selected role: " .. role.name)

    local sourceRoot = getSourceRoot()
    print("Source root: " .. sourceRoot)

    local overwrite = confirm("Overwrite existing installed files?", true)
    local files = combineFiles(role)
    local useLocalSources = hasLocalSources(sourceRoot, files)

    if useLocalSources then
        print("Install mode: local files")
    else
        print("Install mode: GitHub download fallback")
        if not http then
            print("ERROR: HTTP API is disabled, and local files are missing.")
            print("Enable HTTP API or run installer from a full local copy.")
            return
        end
    end

    print("")
    print("Installing files...")

    local totalCopied = 0
    local totalSkipped = 0
    local allErrors = {}

    for _, relativePath in ipairs(files) do
        local ok, skipped, err
        if useLocalSources then
            ok, skipped, err = installFileFromLocal(sourceRoot, relativePath, overwrite)
        else
            ok, skipped, err = installFileFromRemote(relativePath, overwrite)
        end

        if ok and skipped then
            totalSkipped = totalSkipped + 1
        elseif ok then
            totalCopied = totalCopied + 1
        else
            table.insert(allErrors, err or ("Install failed for " .. relativePath))
        end

        local status = ok and (skipped and "skipped" or "installed") or "error"
        print("- " .. relativePath .. " (" .. status .. ")")
    end

    local tokenCreated = writeTokenIfMissing()
    local roleFileOk = writeRoleFile(role.id)

    print("")
    print("Writing startup...")
    local startupOk, startupErr = writeStartup(role.startupProgram)

    print("")
    print("Install complete")
    print("Installed files: " .. tostring(totalCopied))
    print("Skipped files: " .. tostring(totalSkipped))

    if tokenCreated then
        print("Created /arcade_token.txt (edit it to match all machines)")
    else
        print("Existing /arcade_token.txt preserved")
    end

    if roleFileOk then
        print("Wrote /arcade_role.txt as " .. role.id)
    else
        print("Failed to write /arcade_role.txt")
    end

    if startupOk then
        print("Startup now runs updater then: " .. role.startupProgram)
    else
        print("Startup write failed: " .. tostring(startupErr))
    end

    if #allErrors > 0 then
        print("")
        print("Warnings:")
        for _, err in ipairs(allErrors) do
            print("- " .. err)
        end
    end

    print("")
    if confirm("Reboot now to test startup?", true) then
        os.reboot()
    else
        print("You can reboot later with: reboot")
    end
end

runInstall()
