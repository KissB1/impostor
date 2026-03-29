wm.log("Loading pristine user config...")
local OUTER_GAP = 10
local INNER_GAP = 10
local BORDER_WIDTH = 4

wm.spawn("waybar")

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
		["Return"] = function()
			wm.spawn("kitty")
		end,
		["Escape"] = function()
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
    d = function()
      wm.spawn("fuzzel")
    end,
		h = function()
			wm.focus_direction("left")
		end,
		j = function()
			wm.focus_direction("down")
		end,
		k = function()
			wm.focus_direction("up")
		end,
		l = function()
			wm.focus_direction("right")
		end,
		q = function()
			wm.close_window()
		end,
	},

	-- ==========================================
	-- 2. TRADITIONAL CHORDS (Hold modifier + Key)
	-- ==========================================
})
-- Bind Ctrl + Left Click (272) to Move
wm.bind_mouse({ "Ctrl" }, 272, "move")

-- Bind Ctrl + Right Click (273) to Resize
wm.bind_mouse({ "Ctrl" }, 273, "resize")
wm.set_inner_gap(INNER_GAP)
wm.set_outer_gap(OUTER_GAP)
wm.set_focused_color(0.6, 0.2, 0.8, 1.0)

-- NOTE Fix wayland first-frame flash
-- ==========================================
-- THE LAYOUT ENGINES
-- ==========================================

local function layout_horizontal(clients, safe_x, safe_y, safe_width, safe_height)
	local count = #clients
	local usable_width = safe_width - (OUTER_GAP * 2)
	local usable_height = safe_height - (OUTER_GAP * 2)
	local total_inner_gaps = (count > 1) and ((count - 1) * INNER_GAP) or 0
	local total_width_per_window = (usable_width - total_inner_gaps) // count

	local window_w = total_width_per_window - (BORDER_WIDTH * 2)
	local window_h = usable_height - (BORDER_WIDTH * 2)

	-- Start at the safe coordinates!
	local current_x = safe_x + OUTER_GAP
	local current_y = safe_y + OUTER_GAP

	for _, client in ipairs(clients) do
		client:set_geometry(current_x, current_y, window_w, window_h)
		current_x = current_x + total_width_per_window + INNER_GAP
	end
end

local function layout_dwindle(clients, safe_x, safe_y, safe_width, safe_height)
	local count = #clients

	-- Track the coordinates and size of the "Remaining Free Space"
	-- Make sure it starts at safe_x and safe_y!
	local rem_x = safe_x + OUTER_GAP
	local rem_y = safe_y + OUTER_GAP
	local rem_w = safe_width - (OUTER_GAP * 2)
	local rem_h = safe_height - (OUTER_GAP * 2)

	local split_vertical = true

	for i, client in ipairs(clients) do
		local b2 = BORDER_WIDTH * 2
		if i == count then
			client:set_geometry(rem_x, rem_y, rem_w - b2, rem_h - b2)
		else
			local calc_w = rem_w
			local calc_h = rem_h

			if split_vertical then
				calc_w = (rem_w - INNER_GAP) // 2
				client:set_geometry(rem_x, rem_y, calc_w - b2, calc_h - b2)
				rem_x = rem_x + calc_w + INNER_GAP
				rem_w = rem_w - calc_w - INNER_GAP
			else
				calc_h = (rem_h - INNER_GAP) // 2
				client:set_geometry(rem_x, rem_y, calc_w - b2, calc_h - b2)
				rem_y = rem_y + calc_h + INNER_GAP
				rem_h = rem_h - calc_h - INNER_GAP
			end
			split_vertical = not split_vertical
		end
	end
end

local function layout_monocle(clients, safe_x, safe_y, safe_width, safe_height)
	local window_w = safe_width - (OUTER_GAP * 2) - (BORDER_WIDTH * 2)
	local window_h = safe_height - (OUTER_GAP * 2) - (BORDER_WIDTH * 2)

	for _, client in ipairs(clients) do
		-- Use safe_x and safe_y so the monocle window dodges the bar
		client:set_geometry(safe_x + OUTER_GAP, safe_y + OUTER_GAP, window_w, window_h)
	end
end

local niri_scroll_offset = 0

local function layout_niri(clients, safe_x, safe_y, safe_width, safe_height)
	local usable_width = safe_width - (OUTER_GAP * 2)
	local window_w = (usable_width - INNER_GAP) // 2 - (BORDER_WIDTH * 2)
	local window_h = safe_height - (OUTER_GAP * 2) - (BORDER_WIDTH * 2)

	local current_x = safe_x + OUTER_GAP + niri_scroll_offset
	local current_y = safe_y + OUTER_GAP

	for _, client in ipairs(clients) do
		client:set_geometry(current_x, current_y, window_w, window_h)
		current_x = current_x + window_w + (BORDER_WIDTH * 2) + INNER_GAP
	end
end

wm.scroll_niri = function(amount)
	niri_scroll_offset = niri_scroll_offset + amount
	wm.log("Niri scroll offset is now: " .. niri_scroll_offset)
end

-- ==========================================
-- WORKSPACE ROUTING
-- ==========================================

local tag_layouts = {
	[1] = layout_dwindle,
	[2] = layout_horizontal,
	[3] = layout_niri,
	[4] = layout_monocle,
}

-- ==========================================
-- THE MASTER TILING ENGINE (Traffic Cop)
-- ==========================================

-- Notice the 6 arguments from Zig!
wm.on_tile = function(clients, safe_x, safe_y, safe_width, safe_height, current_tag)
	if #clients == 0 then
		return
	end

	local layout_func = tag_layouts[current_tag] or layout_horizontal

	-- Pass the safe coordinates to the selected layout
	layout_func(clients, safe_x, safe_y, safe_width, safe_height)
end

wm.log("Config loaded!")

