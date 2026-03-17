wm.log("Loading pristine user config...")

wm.setup_chords({
    
    -- ==========================================
    -- 1. PURE VIM SEQUENCES (Tap, Tap, Tap)
    -- ==========================================
    Alt_L = {
        leader = "Alt",
        r = {
            desc = "Run/Apps",
            b = function() wm.spawn("zen-browser") end,
            c = function() wm.spawn("code") end
        }
    },
    
    space = {
        leader = "Spacebar",
        f = {
            desc = "Find",
            f = function() wm.log("Finding files...") end,
            w = function() wm.log("Finding words...") end,
        }
    },

    -- ==========================================
    -- 2. TRADITIONAL CHORDS (Hold modifier + Key)
    -- ==========================================
    ["Super+Return"] = function() wm.spawn("kitty") end,
    ["Super+Escape"] = function() wm.exit() end,

})

wm.log("Config loaded!")