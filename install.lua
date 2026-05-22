local INSTALLER_TITLE = "CC Arcade Installer"

local roles = {
    {
        key = "1",
        name = "Central Server",
        startupProgram = "/server/main.lua",
        paths = {
            { src = "shared", dst = "/shared" },
            { src = "server", dst = "/server" },
            { src = "arcade_token.example.txt", dst = "/arcade_token.example.txt" },
        },
    },
    {
        key = "2",
        name = "Front Desk Admin",
        startupProgram = "/frontdesk/main.lua",
        paths = {
            { src = "shared", dst = "/shared" },
            { src = "frontdesk", dst = "/frontdesk" },
            { src = "arcade_token.example.txt", dst = "/arcade_token.example.txt" },
        },
    },
    {
        key = "3",
        name = "Balance Checker Kiosk",
        startupProgram = "/kiosk/main.lua",
        paths = {
            { src = "shared", dst = "/shared" },
            { src = "kiosk", dst = "/kiosk" },
            { src = "arcade_token.example.txt", dst = "/arcade_token.example.txt" },
        },
    },
    {
        key = "4",
        name = "Game Cabinet Client",
        startupProgram = "/game/main.lua",
        paths = {
            { src = "shared", dst = "/shared" },
            { src = "game", dst = "/game" },
            { src = "arcade_token.example.txt", dst = "/arcade_token.example.txt" },
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
    if not fs.exists(path) then
        fs.makeDir(path)
    end
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

local function copyPath(src, dst, overwrite)
    if not fs.exists(src) then
        return 0, 1, { "Missing source: " .. src }
    end

    local copied = 0
    local skipped = 0
    local errors = {}

    local function copyRecursive(fromPath, toPath)
        if fs.isDir(fromPath) then
            ensureDir(toPath)
            for _, name in ipairs(listDir(fromPath)) do
                copyRecursive(fs.combine(fromPath, name), fs.combine(toPath, name))
            end
            return
        end

        if fs.exists(toPath) then
            if overwrite then
                fs.delete(toPath)
            else
                skipped = skipped + 1
                return
            end
        end

        local ok, err = pcall(fs.copy, fromPath, toPath)
        if ok then
            copied = copied + 1
        else
            table.insert(errors, "Copy failed: " .. fromPath .. " -> " .. toPath .. " (" .. tostring(err) .. ")")
        end
    end

    copyRecursive(src, dst)
    return copied, skipped, errors
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

    print("")
    print("Installing files...")

    local totalCopied = 0
    local totalSkipped = 0
    local allErrors = {}

    for _, map in ipairs(role.paths) do
        local src = fs.combine(sourceRoot, map.src)
        local dst = map.dst
        local copied, skipped, errors = copyPath(src, dst, overwrite)

        totalCopied = totalCopied + copied
        totalSkipped = totalSkipped + skipped

        for _, err in ipairs(errors) do
            table.insert(allErrors, err)
        end

        print("- " .. map.src .. " -> " .. map.dst .. " (copied " .. tostring(copied) .. ", skipped " .. tostring(skipped) .. ")")
    end

    local tokenCreated = writeTokenIfMissing()

    print("")
    print("Writing startup...")
    local startupOk, startupErr = writeStartup(role.startupProgram)

    print("")
    print("Install complete")
    print("Copied files: " .. tostring(totalCopied))
    print("Skipped files: " .. tostring(totalSkipped))

    if tokenCreated then
        print("Created /arcade_token.txt (edit it to match all machines)")
    else
        print("Existing /arcade_token.txt preserved")
    end

    if startupOk then
        print("Startup now runs: " .. role.startupProgram)
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
