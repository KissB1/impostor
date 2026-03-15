const std = @import("std");

const impostor = @import("impostor");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

const Server = @import("server.zig").Server;
const lua = @import("server.zig").lua;
const gpa = std.heap.c_allocator; // Use the C allocator (malloc/free)

pub const std_options = @import("util/logger.zig").options;
pub fn main() anyerror!void {
    // 1. ADD THIS LINE: Trigger the Zig logger timer immediately at startup!
    std.log.info("Starting Impostor WM...", .{});

    // 2. Now wlroots and Zig will share the exact same starting time
    wlr.log.init(.debug, null);
    // This Server struct will hold all of our compositor's state
    var server: Server = undefined;
    // Initialize all the server components
    try server.init();
    // Ensure we clean up all resources when main() exits
    defer server.deinit();

    // Set up the Wayland socket that clients will connect to
    var buf: [11]u8 = undefined;
    const socket = try server.wl_server.addSocketAuto(&buf);

    server.socket_name = socket;
    // Check if the user passed a command-line argument to run at startup
    if (std.os.argv.len >= 2) {
        const cmd = std.mem.span(std.os.argv[1]);
        // Prepare to launch the command using /bin/sh
        var child = std.process.Child.init(&[_][]const u8{ "/bin/sh", "-c", cmd }, gpa);

        var env_map = try std.process.getEnvMap(gpa);
        defer env_map.deinit();
        // Set the WAYLAND_DISPLAY environment variable so the new program
        // knows which Wayland server (ours) to connect to.
        try env_map.put("WAYLAND_DISPLAY", socket);
        child.env_map = &env_map;
        try child.spawn(); // Launch the startup command
    }
    // --- EXECUTE LUA SCRIPT ---
    //TODO
    const filePath = "/home/kissb/zig/impostor/config.lua";

    // 1. Load the Lua file
    if (lua.luaL_loadfilex(server.lua_state, filePath, null) != lua.LUA_OK) {
        // Use lua_tolstring instead of lua_tostring
        const err_msg = lua.lua_tolstring(server.lua_state, -1, null);
        std.log.err("Lua Load Error: {s}", .{err_msg});
        lua.lua_pop(server.lua_state, 1); // Clean up the stack
    }
    // 2. Execute the loaded file
    else if (lua.lua_pcallk(server.lua_state, 0, lua.LUA_MULTRET, 0, 0, null) != lua.LUA_OK) {
        // Use lua_tolstring instead of lua_tostring
        const err_msg = lua.lua_tolstring(server.lua_state, -1, null);
        std.log.err("Lua Runtime Error: {s}", .{err_msg});
        lua.lua_pop(server.lua_state, 1); // Clean up the stack
    }
    // Success!
    else {
        std.log.info("Lua config loaded successfully!", .{});
    }
    // Start the wlroots backend (e.g., DRM, X11, Wayland)
    try server.backend.start();

    // Log the socket name and run the server's event loop.
    // This function will block until the compositor is terminated.
    std.log.info("Running compositor on WAYLAND_DISPLAY={s}", .{socket});
    server.wl_server.run();
}
