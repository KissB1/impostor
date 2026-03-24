wm.log("Loading pristine user config...")
local OUTER_GAP = 10
local INNER_GAP = 10
local BORDER_WIDTH = 4
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
		["3"] = function()
			wm.set_workspace(3)
		end,

		["4"] = function()
			wm.set_workspace(4)
		end,
		["5"] = function()
			wm.set_workspace(5)
		end,
		["6"] = function()
			wm.set_workspace(6)
		end,
		["7"] = function()
			wm.set_workspace(7)
		end,
		["8"] = function()
			wm.set_workspace(8)
		end,
		["9"] = function()
			wm.set_workspace(9)
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
-- Bind Ctrl + Left Click (272) to Move
wm.bind_mouse({"Ctrl"}, 272, "move")

-- Bind Ctrl + Right Click (273) to Resize
wm.bind_mouse({"Ctrl"}, 273, "resize")
wm.set_inner_gap(INNER_GAP)
wm.set_outer_gap(OUTER_GAP)
wm.set_focused_color(0.6, 0.2, 0.8, 1.0)

-- NOTE Fix wayland first-frame flash
local function layout_horizontal(clients, screen_width, screen_height)
    local count = #clients
    local usable_width = screen_width - (OUTER_GAP * 2)
    local usable_height = screen_height - (OUTER_GAP * 2)
    local total_inner_gaps = (count > 1) and ((count - 1) * INNER_GAP) or 0
    local total_width_per_window = (usable_width - total_inner_gaps) // count
    
    local window_w = total_width_per_window - (BORDER_WIDTH * 2)
    local window_h = usable_height - (BORDER_WIDTH * 2)

    local current_x = OUTER_GAP
    for _, client in ipairs(clients) do
        client:set_geometry(current_x, OUTER_GAP, window_w, window_h)
        current_x = current_x + total_width_per_window + INNER_GAP
    end
end

local function layout_dwindle(clients, screen_width, screen_height)
    local count = #clients
    
    -- Track the coordinates and size of the "Remaining Free Space"
    local rem_x = OUTER_GAP
    local rem_y = OUTER_GAP
    local rem_w = screen_width - (OUTER_GAP * 2)
    local rem_h = screen_height - (OUTER_GAP * 2)

    -- True = Cut vertically (Left/Right)
    -- False = Cut horizontally (Top/Bottom)
    local split_vertical = true 

    for i, client in ipairs(clients) do
        local b2 = BORDER_WIDTH * 2

        if i == count then
            -- The last window always takes up 100% of whatever space is left!
            client:set_geometry(rem_x, rem_y, rem_w - b2, rem_h - b2)
        else
            -- Not the last window? Take half the remaining space.
            local calc_w = rem_w
            local calc_h = rem_h

            if split_vertical then
                -- Cut the width in half
                calc_w = (rem_w - INNER_GAP) // 2
                client:set_geometry(rem_x, rem_y, calc_w - b2, calc_h - b2)
                
                -- Shift the "Remaining Space" box to the right
                rem_x = rem_x + calc_w + INNER_GAP
                rem_w = rem_w - calc_w - INNER_GAP
            else
                -- Cut the height in half
                calc_h = (rem_h - INNER_GAP) // 2
                client:set_geometry(rem_x, rem_y, calc_w - b2, calc_h - b2)
                
                -- Shift the "Remaining Space" box downwards
                rem_y = rem_y + calc_h + INNER_GAP
                rem_h = rem_h - calc_h - INNER_GAP
            end

            -- Toggle the cut direction for the next window in the loop!
            split_vertical = not split_vertical
        end
    end
end

local function layout_monocle(clients, screen_width, screen_height)
    -- Every window takes up the entire usable screen space, stacked on top of each other
    local window_w = screen_width - (OUTER_GAP * 2) - (BORDER_WIDTH * 2)
    local window_h = screen_height - (OUTER_GAP * 2) - (BORDER_WIDTH * 2)

    for _, client in ipairs(clients) do
        client:set_geometry(OUTER_GAP, OUTER_GAP, window_w, window_h)
    end
end

-- We need a variable to remember where we are scrolled to!
local niri_scroll_offset = 0

local function layout_niri(clients, screen_width, screen_height)
    -- Niri windows usually have a fixed width. Let's make them exactly half the screen.
    local usable_width = screen_width - (OUTER_GAP * 2)
    local window_w = (usable_width - INNER_GAP) // 2 - (BORDER_WIDTH * 2)
    local window_h = screen_height - (OUTER_GAP * 2) - (BORDER_WIDTH * 2)

    -- THE MAGIC: We shift the starting X coordinate by the scroll offset!
    local current_x = OUTER_GAP + niri_scroll_offset

    for i, client in ipairs(clients) do
        client:set_geometry(current_x, OUTER_GAP, window_w, window_h)
        
        -- Move the X cursor to the right for the next window, into infinity
        current_x = current_x + window_w + (BORDER_WIDTH * 2) + INNER_GAP
    end
end

-- Let's create a global function so we can easily change the scroll later
wm.scroll_niri = function(amount)
    niri_scroll_offset = niri_scroll_offset + amount
    wm.log("Niri scroll offset is now: " .. niri_scroll_offset)
    -- Note: This won't visually update until the next time reTile is called!
end

-- ==========================================
-- 2. WORKSPACE ROUTING
-- ==========================================

-- A map of Tag Number to Layout Function
-- Remember: Tags in Wayland are bitmasks! 
-- Workspace 1 = 1, Workspace 2 = 2, Workspace 3 = 4, Workspace 4 = 8, etc.
local tag_layouts = {
    [1] = layout_dwindle, -- Workspace 1 uses Dwindle
    [2] = layout_horizontal,    -- Workspace 2 uses Horizontal
	[3] = layout_niri,         -- Workspace 3 uses Niri
	[4] = layout_monocle,       -- Workspace 4 uses Monocle
}

-- ==========================================
-- 3. THE TILING ENGINE (Traffic Cop)
-- ==========================================

wm.on_tile = function(clients, screen_width, screen_height, current_tag)
    if #clients == 0 then return end

    -- Look up the layout for this tag. If it doesn't exist, default to horizontal.
    local layout_func = tag_layouts[current_tag] or layout_horizontal
    
    -- Execute the chosen layout
    layout_func(clients, screen_width, screen_height)
end


wm.log("Config loaded!")
