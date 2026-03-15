// In lua/methods.zig
const std = @import("std");

// We need the Lua headers to interact with the stack
const lua = @import("../server.zig").lua;
// Go up one directory to get the Server struct definition
const Server = @import("../server.zig").Server;

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

// 2. Your retile wrapper (you can add this now!)
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
        // Use our scoped logger! It will automatically format as [lua]
        lua_log.info("{s}", .{msg});
    } else {
        lua_log.warn("Tried to log a non-string value", .{});
    }

    return 0;
}
