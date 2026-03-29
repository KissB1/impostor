// In lua/methods.zig
const std = @import("std");

// We need the Lua headers to interact with the stack
const lua = @import("../server.zig").lua;
// Go up one directory to get the Server struct definition
const Server = @import("../server.zig").Server;

const Output = @import("../output/output.zig").Output;

const keys = @import("../input/keys.zig");
const wlr = @import("wlroots");
const Toplevel = @import("../view/toplevel.zig").Toplevel;

// --- THE MAGIC REGISTRATION ARRAY ---
pub fn registerAll(L: ?*lua.lua_State, server: *Server) void {
    // Create a new empty table on the Lua stack
    lua.lua_newtable(L);

    // Push the upvalue (*Server) onto the stack
    lua.lua_pushlightuserdata(L, server);

    // Define the array of all your API methods.
    // It MUST end with a null terminator so Lua knows where the list stops.
    const funcs = [_]lua.luaL_Reg{
        .{ .name = "spawn", .func = spawn },
        .{ .name = "retile", .func = retile },
        .{ .name = "log", .func = log_msg },
        .{ .name = "_register_node", .func = register_node },
        .{ .name = "exit", .func = terminate },
        .{ .name = "set_workspace", .func = set_workspace },
        .{ .name = "focus_direction", .func = focus_direction },
        .{ .name = "close_window", .func = close_window },
        .{ .name = "set_inner_gap", .func = set_inner_gap },
        .{ .name = "set_outer_gap", .func = set_outer_gap },
        .{ .name = "set_border_width", .func = set_border_width },
        .{ .name = "set_focused_color", .func = set_focused_color },
        .{ .name = "bind_mouse", .func = bind_mouse },
        .{ .name = null, .func = null }, // Sentinel
    };

    // This single Lua C-API call loops over the array, grabs the 1 upvalue
    // we pushed, and attaches it to every single function in the table.
    lua.luaL_setfuncs(L, &funcs, 1);

    _ = lua.luaL_newmetatable(L, "Client");
    lua.lua_pushcfunction(L, client_index);
    lua.lua_setfield(L, -2, "__index");
    lua.lua_pop(L, 1); // Pop the metatable off the stack

    // Take the table we just filled and assign it to the global variable "wm"
    lua.lua_setglobal(L, "wm");
}
// 1. Your spawn wrapper
pub fn spawn(L: ?*lua.lua_State) callconv(.c) i32 {
    var len: usize = 0;
    const cmd_c_str = lua.lua_tolstring(L, 1, &len);
    if (cmd_c_str == null) return 0;

    const cmd = cmd_c_str[0..len];
    const server_ptr = lua.lua_touserdata(L, lua.lua_upvalueindex(1));
    const server: *Server = @ptrCast(@alignCast(server_ptr));

    server.spawnProgram(cmd) catch |err| {
        std.log.err("Lua failed to spawn '{s}': {}", .{ cmd, err });
    };
    return 0;
}

// 2. Your retile wrapper
pub fn retile(L: ?*lua.lua_State) callconv(.c) i32 {
    const server_ptr = lua.lua_touserdata(L, lua.lua_upvalueindex(1));
    const server: *Server = @ptrCast(@alignCast(server_ptr));

    server.reTile();
    return 0;
}

const lua_log = std.log.scoped(.lua);
pub fn log_msg(L: ?*lua.lua_State) callconv(.c) i32 {
    // 1. Grab the string from Lua
    var len: usize = 0;
    const msg_c_str = lua.lua_tolstring(L, 1, &len);

    if (msg_c_str != null) {
        const msg = msg_c_str[0..len];
        lua_log.info("{s}", .{msg});
    } else {
        lua_log.warn("Tried to log a non-string value", .{});
    }

    return 0;
}

pub fn register_node(L: ?*lua.lua_State) callconv(.c) i32 {
    const server_ptr = lua.lua_touserdata(L, lua.lua_upvalueindex(1));
    const server: *Server = @ptrCast(@alignCast(server_ptr));

    // Arg 1: The integer state this key lives in
    const current_state: u32 = @intCast(lua.lua_tointegerx(L, 1, null));

    // Arg 2: Parse the Modifiers Table
    var mods = keys.ModMask{};
    lua.lua_pushnil(L);
    while (lua.lua_next(L, 2) != 0) {
        if (lua.lua_type(L, -1) == lua.LUA_TSTRING) {
            const mod_slice = std.mem.span(lua.lua_tolstring(L, -1, null));
            if (std.mem.eql(u8, mod_slice, "Super")) mods.super = true else if (std.mem.eql(u8, mod_slice, "Shift")) mods.shift = true else if (std.mem.eql(u8, mod_slice, "Ctrl")) mods.ctrl = true else if (std.mem.eql(u8, mod_slice, "Alt")) mods.alt = true;
        }
        lua.lua_pop(L, 1);
    }

    // Arg 3: The key string
    var key_str = std.mem.span(lua.lua_tolstring(L, 3, null));
    // Force generic modifier names to become Left-sided in memory
    if (std.mem.eql(u8, key_str, "Super")) key_str = "Super_L";
    if (std.mem.eql(u8, key_str, "Alt")) key_str = "Alt_L";
    if (std.mem.eql(u8, key_str, "Ctrl")) key_str = "Control_L";
    if (std.mem.eql(u8, key_str, "Shift")) key_str = "Shift_L";

    const keysym = @import("xkbcommon").Keysym.fromName(key_str, .no_flags);
    if (keysym == .NoSymbol) {
        std.log.err("[lua] Invalid FSM key: {s}", .{key_str});
        return 0;
    }

    // Arg 4 & 5: Is it a folder or a file?
    const is_folder = lua.lua_toboolean(L, 4) != 0;
    var action: keys.BindAction = undefined;

    if (is_folder) {
        const next_state: u32 = @intCast(lua.lua_tointegerx(L, 5, null));
        action = .{ .next_state = next_state };
        std.log.info("[lua] Node: State {d} + '{s}' -> Folder (State {d})", .{ current_state, key_str, next_state });
    } else {
        lua.lua_pushvalue(L, 5); // It's a file. Push function to top.
        const registry_id = lua.luaL_ref(L, lua.LUA_REGISTRYINDEX);
        action = .{ .exec_lua = registry_id };
        std.log.info("[lua] Node: State {d} + '{s}' -> File (Registry {d})", .{ current_state, key_str, registry_id });
    }

    // Save to the map!
    const bind = keys.Keybind{ .state = current_state, .modifiers = mods, .keysym = keysym };
    server.keybinds.put(bind, action) catch |err| {
        std.log.err("Failed to save FSM node: {}", .{err});
    };

    return 0;
}

pub fn terminate(L: ?*lua.lua_State) callconv(.c) i32 {
    const server_ptr = lua.lua_touserdata(L, lua.lua_upvalueindex(1));
    const server: *Server = @ptrCast(@alignCast(server_ptr));

    server.wl_server.terminate();
    return 0;
}

pub fn set_workspace(L: ?*lua.lua_State) callconv(.c) i32 {
    const server_ptr = lua.lua_touserdata(L, lua.lua_upvalueindex(1));
    const server: *Server = @ptrCast(@alignCast(server_ptr));

    // Get the workspace number from Lua (e.g., 1 to 9)
    const ws_num: u5 = @intCast(lua.lua_tointegerx(L, 1, null));

    // --- 1. Find the active monitor! ---
    // Where is the user's mouse right now?
    var active_output = server.output_layout.outputAt(server.cursor.x, server.cursor.y);
    if (active_output == null) {
        // Fallback to the first connected monitor if the mouse is somehow in the void
        active_output = server.output_layout.outputs.first().?.output;
    }

    // --- 2. Grab our custom Output struct ---
    // We stored our Output pointer in the wlr_output.data field earlier!
    const out_data = active_output.?.data orelse return 0;

    // Note: If 'Output' isn't directly imported in this file, use 'server.Output'
    const out_struct: *Output = @ptrCast(@alignCast(out_data));

    // --- 3. Change the tag ONLY for this monitor ---
    // Convert the number to a bitmask (1 -> 0b001, 2 -> 0b010)
    out_struct.current_tags = @as(u32, 1) << (ws_num - 1);

    // 4. Retile the screen to hide old windows and show the new ones!
    server.reTile();
    return 0;
}

pub fn focus_direction(L: ?*lua.lua_State) callconv(.c) i32 {
    const server_ptr = lua.lua_touserdata(L, lua.lua_upvalueindex(1));
    const server: *Server = @ptrCast(@alignCast(server_ptr));

    // 1. Get the requested direction ("left", "right", "up", "down")
    var len: usize = 0;
    const dir_str = lua.lua_tolstring(L, 1, &len);
    if (dir_str == null) return 0;
    const dir = dir_str[0..len];

    // 2. Find the currently focused window (if none, just abort)
    const focused_surface = server.seat.keyboard_state.focused_surface orelse return 0;
    const xdg_surface = wlr.XdgSurface.tryFromWlrSurface(focused_surface) orelse return 0;

    var current_toplevel: ?*Toplevel = null;
    if (xdg_surface.data) |data_ptr| {
        const scene_tree = @as(*wlr.SceneTree, @ptrCast(@alignCast(data_ptr)));
        if (scene_tree.node.parent) |container_node| {
            if (container_node.node.data) |container_data_ptr| {
                current_toplevel = @as(?*Toplevel, @ptrCast(@alignCast(container_data_ptr)));
            }
        }
    }
    const current = current_toplevel orelse return 0;

    // Calculate current window's center point
    const cur_geom = current.xdg_toplevel.base.geometry;
    const cur_cx = @as(f32, @floatFromInt(current.x)) + @as(f32, @floatFromInt(cur_geom.width)) / 2.0;
    const cur_cy = @as(f32, @floatFromInt(current.y)) + @as(f32, @floatFromInt(cur_geom.height)) / 2.0;

    // 3. Scan all windows for the closest neighbor
    var best_match: ?*Toplevel = null;
    var min_dist_sq: f32 = std.math.floatMax(f32);

    // Iterate through the linked list safely
    var it = server.toplevels.link.prev;
    while (it != &server.toplevels.link) {
        const target: *Toplevel = @fieldParentPtr("link", it.?);
        it = it.?.prev; // Advance early

        // Skip if it's the window we are already on, or if it's on a hidden workspace
        if (target == current or (target.tags & server.getActiveTags()) == 0) continue;

        // Calculate target's center point
        const target_geom = target.xdg_toplevel.base.geometry;
        const target_cx = @as(f32, @floatFromInt(target.x)) + @as(f32, @floatFromInt(target_geom.width)) / 2.0;
        const target_cy = @as(f32, @floatFromInt(target.y)) + @as(f32, @floatFromInt(target_geom.height)) / 2.0;

        // The Directional Filter (Cone of Vision)
        var valid = false;
        if (std.mem.eql(u8, dir, "left")) valid = target_cx < cur_cx;
        if (std.mem.eql(u8, dir, "right")) valid = target_cx > cur_cx;
        if (std.mem.eql(u8, dir, "up")) valid = target_cy < cur_cy;
        if (std.mem.eql(u8, dir, "down")) valid = target_cy > cur_cy;

        // If it's in the right direction, calculate Euclidean distance squared
        if (valid) {
            const dx = target_cx - cur_cx;
            const dy = target_cy - cur_cy;
            const dist_sq = (dx * dx) + (dy * dy);

            if (dist_sq < min_dist_sq) {
                min_dist_sq = dist_sq;
                best_match = target;
            }
        }
    }

    // 4. Crown the winner and hand it to wlroots!
    if (best_match) |winner| {
        server.focusView(winner, winner.xdg_toplevel.base.surface);
    }

    return 0;
}
pub fn close_window(L: ?*lua.lua_State) callconv(.c) i32 {
    const server_ptr = lua.lua_touserdata(L, lua.lua_upvalueindex(1));
    const server: *Server = @ptrCast(@alignCast(server_ptr));

    // 1. Ask the Wayland seat what surface currently has the keyboard focus
    if (server.seat.keyboard_state.focused_surface) |focused_surface| {
        // 2. Make sure it's actually an XDG Surface (a real window, not a wallpaper/bar)
        if (wlr.XdgSurface.tryFromWlrSurface(focused_surface)) |xdg_surface| {
            // 3. Send the polite "Close" request to the application
            if (xdg_surface.role_data.toplevel) |toplevel| {
                toplevel.sendClose();
            }
        }
    }

    return 0;
}
pub fn set_inner_gap(L: ?*lua.lua_State) callconv(.c) i32 {
    const server_ptr = lua.lua_touserdata(L, lua.lua_upvalueindex(1));
    const server: *Server = @ptrCast(@alignCast(server_ptr));

    server.inner_gap = @intCast(lua.lua_tointegerx(L, 1, null));
    server.reTile();
    return 0;
}

pub fn set_outer_gap(L: ?*lua.lua_State) callconv(.c) i32 {
    const server_ptr = lua.lua_touserdata(L, lua.lua_upvalueindex(1));
    const server: *Server = @ptrCast(@alignCast(server_ptr));

    server.outer_gap = @intCast(lua.lua_tointegerx(L, 1, null));
    server.reTile();
    return 0;
}

pub fn set_border_width(L: ?*lua.lua_State) callconv(.c) i32 {
    const server_ptr = lua.lua_touserdata(L, lua.lua_upvalueindex(1));
    const server: *Server = @ptrCast(@alignCast(server_ptr));

    server.border_width = @intCast(lua.lua_tointegerx(L, 1, null));
    server.reTile();
    return 0;
}

// Helper to grab colors from Lua (expects 4 floats: R, G, B, A)
pub fn set_focused_color(L: ?*lua.lua_State) callconv(.c) i32 {
    const server_ptr = lua.lua_touserdata(L, lua.lua_upvalueindex(1));
    const server: *Server = @ptrCast(@alignCast(server_ptr));

    server.focused_color[0] = @floatCast(lua.lua_tonumberx(L, 1, null));
    server.focused_color[1] = @floatCast(lua.lua_tonumberx(L, 2, null));
    server.focused_color[2] = @floatCast(lua.lua_tonumberx(L, 3, null));
    server.focused_color[3] = @floatCast(lua.lua_tonumberx(L, 4, null));

    // You'd ideally iterate over visible windows here and update the active one,
    // or just let it apply on the next focus change.
    return 0;
}
// lua/methods.zig
pub fn bind_mouse(L: ?*lua.lua_State) callconv(.c) i32 {
    const server_ptr = lua.lua_touserdata(L, lua.lua_upvalueindex(1));
    const server: *Server = @ptrCast(@alignCast(server_ptr));

    // Arg 1: Modifiers Table
    var mods = keys.ModMask{};
    lua.lua_pushnil(L);
    while (lua.lua_next(L, 1) != 0) {
        if (lua.lua_type(L, -1) == lua.LUA_TSTRING) {
            const mod_slice = std.mem.span(lua.lua_tolstring(L, -1, null));
            if (std.mem.eql(u8, mod_slice, "Super")) mods.super = true else if (std.mem.eql(u8, mod_slice, "Shift")) mods.shift = true else if (std.mem.eql(u8, mod_slice, "Ctrl")) mods.ctrl = true else if (std.mem.eql(u8, mod_slice, "Alt")) mods.alt = true;
        }
        lua.lua_pop(L, 1);
    }

    // Arg 2: Mouse Button (272 = Left, 273 = Right, 274 = Middle)
    const button: u32 = @intCast(lua.lua_tointegerx(L, 2, null));

    // Arg 3: Action String ("move" or "resize")
    const action_str = std.mem.span(lua.lua_tolstring(L, 3, null));
    var action: keys.MouseAction = .move;

    if (std.mem.eql(u8, action_str, "resize")) {
        action = .resize;
    } else if (!std.mem.eql(u8, action_str, "move")) {
        std.log.err("[lua] Invalid mouse action: {s}", .{action_str});
        return 0;
    }

    // Save to the map!
    const bind = keys.MouseBind{ .modifiers = mods, .button = button };
    server.mousebinds.put(bind, action) catch |err| {
        std.log.err("Failed to save mouse bind: {}", .{err});
    };

    return 0;
}

pub fn client_index(L: ?*lua.lua_State) callconv(.c) i32 {
    // 1. Open the lockbox (get the Toplevel pointer from Userdata)
    const userdata = lua.lua_touserdata(L, 1);
    const ptr: **Toplevel = @ptrCast(@alignCast(userdata));
    const toplevel = ptr.*;

    // 2. What property is Lua asking for?
    var len: usize = 0;
    const key_c_str = lua.lua_tolstring(L, 2, &len);
    if (key_c_str == null) return 0;
    const key = key_c_str[0..len];

    // 3. Hand the correct data back to Lua!
    if (std.mem.eql(u8, key, "app_id")) {
        if (toplevel.xdg_toplevel.app_id) |app_id| {
            _ = lua.lua_pushstring(L, app_id);
        } else {
            _ = lua.lua_pushstring(L, "unknown");
        }
        return 1; // We pushed 1 thing to the stack
    } else if (std.mem.eql(u8, key, "title")) {
        if (toplevel.xdg_toplevel.title) |title| {
            _ = lua.lua_pushstring(L, title);
        } else {
            _ = lua.lua_pushstring(L, "unknown");
        }
        return 1;
    } else if (std.mem.eql(u8, key, "set_geometry")) {
        // If they asked for a function, give them the C-function
        lua.lua_pushcfunction(L, client_set_geometry);
        return 1;
    }

    return 0; // Property not found
}
pub fn client_set_geometry(L: ?*lua.lua_State) callconv(.c) i32 {
    // 1. Get the Toplevel (Arg 1, because Lua calls it with client:set_geometry())
    const userdata = lua.lua_touserdata(L, 1);
    const ptr: **Toplevel = @ptrCast(@alignCast(userdata));
    const toplevel = ptr.*;

    // 2. Get the X, Y, Width, and Height from Lua
    const x: i32 = @intCast(lua.lua_tointegerx(L, 2, null));
    const y: i32 = @intCast(lua.lua_tointegerx(L, 3, null));
    const w: i32 = @intCast(lua.lua_tointegerx(L, 4, null));
    const h: i32 = @intCast(lua.lua_tointegerx(L, 5, null));

    // 3. Apply the math to the Wayland window
    toplevel.x = x;
    toplevel.y = y;
    toplevel.scene_tree.node.setPosition(x, y);
    _ = toplevel.xdg_toplevel.setSize(w, h);

    // 4. Update the border node to match the new size
    const b = toplevel.server.border_width;
    toplevel.border_node.setSize(w + (b * 2), h + (b * 2));
    toplevel.border_node.node.setPosition(0, 0);
    toplevel.surface_scene_tree.node.setPosition(b, b);

    return 0;
}

// We will call this from server.zig whenever we want to pass a window to Lua
pub fn push_client(L: ?*lua.lua_State, toplevel: *Toplevel) void {
    // 1. Allocate memory inside Lua to hold our Zig pointer
    const userdata = lua.lua_newuserdata(L, @sizeOf(*Toplevel));
    const ptr: **Toplevel = @ptrCast(@alignCast(userdata));
    ptr.* = toplevel;

    // 2. Tape the "Client" instruction manual to the box
    _ = lua.luaL_getmetatable(L, "Client");
    _ = lua.lua_setmetatable(L, -2);
}
