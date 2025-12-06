const std = @import("std");

const impostor = @import("impostor");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

const Server = @import("server.zig").Server;
const gpa = std.heap.c_allocator; // Use the C allocator (malloc/free)
//
pub fn main() anyerror!void {
    // Initialize wlroots logging at a debug level
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

    // Start the wlroots backend (e.g., DRM, X11, Wayland)
    try server.backend.start();

    // Log the socket name and run the server's event loop.
    // This function will block until the compositor is terminated.
    std.log.info("Running compositor on WAYLAND_DISPLAY={s}", .{socket});
    server.wl_server.run();
}
