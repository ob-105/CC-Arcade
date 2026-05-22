local src = "/install.lua"

if not fs.exists(src) then
    print("Missing /install.lua")
    print("Download it first, then run this fixer again.")
    return
end

print("Running installer to regenerate startup...")
shell.run(src)
