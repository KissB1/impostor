wm.log("Initializing Impostor WM...")

-- Now everything lives nicely under the 'wm' namespace!
wm.spawn("kitty")
wm.retile()

wm.bind_key({ "Super", "Shift" }, "Return", function()
    wm.log("Executing Super+Shift+Return macro!")
    wm.spawn("kitty")
end)

-- Test a simple bind: Super + b opens the browser
wm.bind_key({ "Super" }, "c", function()
    wm.log("Opening code...")
    wm.spawn("code")
end)

wm.bind_key({ "Super" }, "Escape", function()
    wm.log("Shutting down compositor...")
    wm.exit()
end)

wm.log("Config fully loaded.")