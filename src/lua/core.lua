-- lua/core.lua
wm.setup_chords = function(tree)
    local next_state_id = 1
    
    -- Splits "Super+Shift+Return" into Mods={"Super", "Shift"}, Keysym="Return"
    local function parse_key(key_str)
        local mods = {}
        local parts = {}
        for part in string.gmatch(key_str, "[^+]+") do
            table.insert(parts, part)
        end
        
        local keysym = parts[#parts]
        for i = 1, #parts - 1 do
            table.insert(mods, parts[i])
        end
        
        return mods, keysym
    end
    
    local function walk(node, current_state)
        for key_str, value in pairs(node) do
            if key_str ~= "name" then
                local mods, keysym = parse_key(key_str)
                
                if type(value) == "table" then
                    local new_state = next_state_id
                    next_state_id = next_state_id + 1
                    wm._register_node(current_state, mods, keysym, true, new_state)
                    walk(value, new_state)
                elseif type(value) == "function" then
                    wm._register_node(current_state, mods, keysym, false, value)
                end
            end
        end
    end
    walk(tree, 0)
end