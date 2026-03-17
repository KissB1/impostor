wm.log("Initializing Impostor WM...")

-- Now everything lives nicely under the 'wm' namespace!
wm.retile()

wm.log("Loading pristine user config...")

wm.setup_chords({
    
    -- ==========================================
    -- 1. PURE VIM SEQUENCES (Tap, Tap, Tap)
    -- ==========================================
    Alt_L = {
        name = "Alt Leader",
        r = {
            b = function() wm.spawn("zen-browser") end,
            c = function() wm.spawn("code") end
        }
    },
    
    -- If you ever want to use the Spacebar as a leader!
    space = {
        name = "Space Leader",
        f = function() wm.log("Space -> f was tapped!") end
    },

    -- ==========================================
    -- 2. TRADITIONAL CHORDS (Hold modifier + Key)
    -- ==========================================
    ["Super+Return"] = function() wm.spawn("kitty") end,
    ["Super+Escape"] = function() wm.exit() end,

})
wm.log("Config fully loaded.")