wm.log("Loading pristine user config...")

wm.setup_chords({

	-- ==========================================
	-- 1. PURE VIM SEQUENCES (Tap, Tap, Tap)
	-- ==========================================
	Alt = {
		leader = "ALT",
		["1"] = function()
			wm.set_workspace(1)
		end,
		["2"] = function()
			wm.set_workspace(2)
		end,
    	["Return"] = function ()
     	 	wm.spawn("kitty")
    	end, 
    	["Escape"] = function ()
      		wm.exit()
    	end,
		r = {
			desc = "Run/Apps",
			b = function()
				wm.spawn("zen-browser")
			end,
			c = function()
				wm.spawn("code")
			end,
		},
		h = function() wm.focus_direction("left") end,
        j = function() wm.focus_direction("down") end,
        k = function() wm.focus_direction("up") end,
        l = function() wm.focus_direction("right") end,
		q = function() wm.close_window() end,
	},

	-- ==========================================
	-- 2. TRADITIONAL CHORDS (Hold modifier + Key)
	-- ==========================================
})
wm.set_inner_gap(10)
wm.set_outer_gap(25)
wm.set_focused_color(0.6, 0.2, 0.8, 1.0)
wm.log("Config loaded!")

