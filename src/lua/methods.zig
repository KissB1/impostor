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
        .{ .name = "bind_key", .func = bind_key },
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

pub fn bind_key(L: ?*lua.lua_State) callconv(.c) i32 {
    const server_ptr = lua.lua_touserdata(L, lua.lua_upvalueindex(1));
    const server: *Server = @ptrCast(@alignCast(server_ptr));

    // validate arguments, table = mods, string = keys, function = action
    if (lua.lua_type(L, 1) != lua.LUA_TTABLE or
        lua.lua_type(L, 2) != lua.LUA_TSTRING or
        lua.lua_type(L, 3) != lua.LUA_TFUNCTION)
    {
        std.log.err("[lua] bind_key requires (table, string, function)", .{});
        return 0;
    }

    // parse the modifier table
    var mods = keys.ModMask{};
    lua.lua_pushnil(L);
    while (lua.lua_next(L, 1) != 0) {
        // Value is at index -1. We check if it's a string.
        if (lua.lua_type(L, -1) == lua.LUA_TSTRING) {
            const mod_slice = std.mem.span(lua.lua_tolstring(L, -1, null));
            if (std.mem.eql(u8, mod_slice, "Super")) mods.super = true else if (std.mem.eql(u8, mod_slice, "Shift")) mods.shift = true else if (std.mem.eql(u8, mod_slice, "Ctrl")) mods.ctrl = true else if (std.mem.eql(u8, mod_slice, "Alt")) mods.alt = true else std.log.warn("[lua] Unknown modifier: {s}", .{mod_slice});
        }
        lua.lua_pop(L, 1);
    }

    const key_str = std.mem.span(lua.lua_tolstring(L, 2, null));
    const keysym = @import("xkbcommon").Keysym.fromName(key_str, .no_flags);
    if (keysym == .NoSymbol) {
        std.log.err("[lua] Invalid key name: {s}", .{key_str});
        return 0;
    }

    // store the function in the lua registry
    lua.lua_pushvalue(L, 3);
    const registry_id = lua.luaL_ref(L, lua.LUA_REGISTRYINDEX);

    // save the mapping to zig's hashmap
    const bind = keys.Keybind{ .modifiers = mods, .keysym = keysym };
    server.keybinds.put(bind, registry_id) catch |err| {
        std.log.err("Failed to save keybind: {}", .{err});
    };

    std.log.info("[lua] Bound '{s}' to Registry ID {d}", .{ key_str, registry_id });
    return 0;
}

pub fn terminate(L: ?*lua.lua_State) callconv(.c) i32 {
    const server_ptr = lua.lua_touserdata(L, lua.lua_upvalueindex(1));
    const server: *Server = @ptrCast(@alignCast(server_ptr));

    server.wl_server.terminate();
    return 0;
}
