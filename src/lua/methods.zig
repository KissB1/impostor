// In lua/methods.zig
const std = @import("std");

// We need the Lua headers to interact with the stack
const lua = @import("../server.zig").lua;
// Go up one directory to get the Server struct definition
const Server = @import("../server.zig").Server;

const keys = @import("../input/keys.zig");

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
        .{ .name = null, .func = null }, // Sentinel
    };

    // This single Lua C-API call loops over the array, grabs the 1 upvalue
    // we pushed, and attaches it to every single function in the table.
    lua.luaL_setfuncs(L, &funcs, 1);

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
    const key_str = std.mem.span(lua.lua_tolstring(L, 3, null));
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
