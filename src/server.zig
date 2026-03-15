pub const lua = @cImport({
    @cInclude("lua.h");
    @cInclude("lualib.h");
    @cInclude("lauxlib.h");
});
const std = @import("std");
const posix = std.posix;

const wl = @import("wayland").server.wl;

const wlr = @import("wlroots");
const xkb = @import("xkbcommon");

const gpa = std.heap.c_allocator;

pub const Keyboard = @import("./input/keyboard.zig").Keyboard;
pub const Output = @import("./output/output.zig").Output;
pub const Toplevel = @import("./view/toplevel.zig").Toplevel;
pub const Popup = @import("./view/popup.zig").Popup;
const lua_api = @import("./lua/methods.zig");
const keys = @import("./input/keys.zig");

pub const Server = struct {
    wl_server: *wl.Server,
    backend: *wlr.Backend,
    renderer: *wlr.Renderer,
    allocator: *wlr.Allocator,
    scene: *wlr.Scene,

    output_layout: *wlr.OutputLayout,
    scene_output_layout: *wlr.SceneOutputLayout,
    new_output: wl.Listener(*wlr.Output) = .init(newOutput),

    xdg_shell: *wlr.XdgShell,
    new_xdg_toplevel: wl.Listener(*wlr.XdgToplevel) = .init(newXdgToplevel),
    new_xdg_popup: wl.Listener(*wlr.XdgPopup) = .init(newXdgPopup),
    toplevels: wl.list.Head(Toplevel, .link) = undefined,

    seat: *wlr.Seat,
    new_input: wl.Listener(*wlr.InputDevice) = .init(newInput),
    request_set_cursor: wl.Listener(*wlr.Seat.event.RequestSetCursor) = .init(requestSetCursor),
    request_set_selection: wl.Listener(*wlr.Seat.event.RequestSetSelection) = .init(requestSetSelection),
    keyboards: wl.list.Head(Keyboard, .link) = undefined,

    cursor: *wlr.Cursor,
    cursor_mgr: *wlr.XcursorManager,
    cursor_motion: wl.Listener(*wlr.Pointer.event.Motion) = .init(cursorMotion),
    cursor_motion_absolute: wl.Listener(*wlr.Pointer.event.MotionAbsolute) = .init(cursorMotionAbsolute),
    cursor_button: wl.Listener(*wlr.Pointer.event.Button) = .init(cursorButton),
    cursor_axis: wl.Listener(*wlr.Pointer.event.Axis) = .init(cursorAxis),
    cursor_frame: wl.Listener(*wlr.Cursor) = .init(cursorFrame),

    cursor_mode: enum { passthrough, move, resize } = .passthrough,
    grabbed_view: ?*Toplevel = null,
    grab_x: f64 = 0,
    grab_y: f64 = 0,
    grab_box: wlr.Box = undefined,
    resize_edges: wlr.Edges = .{},

    socket_name: []const u8 = undefined,

    // border
    border_width: i32,
    focused_color: [4]f32,
    unfocused_color: [4]f32,

    //keybind hashmap
    keybinds: std.AutoHashMap(keys.Keybind, i32),

    // lua state, this is the main lua pointer, akin to the file pointer when opening a file.
    lua_state: *lua.lua_State,

    pub fn init(server: *Server) !void {
        // Lua must be initialized first so the client can connect to the server at startup

        const L = lua.luaL_newstate() orelse return error.LuaInitFailed;
        lua.luaL_openlibs(L);
        lua_api.registerAll(L, server);

        const wl_server = try wl.Server.create();
        const loop = wl_server.getEventLoop();
        const backend = try wlr.Backend.autocreate(loop, null);
        const renderer = try wlr.Renderer.autocreate(backend);
        const output_layout = try wlr.OutputLayout.create(wl_server);
        const scene = try wlr.Scene.create();
        server.* = .{
            .wl_server = wl_server,
            .lua_state = L,
            .backend = backend,
            .renderer = renderer,
            .allocator = try wlr.Allocator.autocreate(backend, renderer),
            .scene = scene,
            .output_layout = output_layout,
            .scene_output_layout = try scene.attachOutputLayout(output_layout),
            .xdg_shell = try wlr.XdgShell.create(wl_server, 2),
            .seat = try wlr.Seat.create(wl_server, "default"),
            .cursor = try wlr.Cursor.create(),
            .cursor_mgr = try wlr.XcursorManager.create(null, 24),
            .border_width = 4,
            .focused_color = .{ 1.0, 0.0, 0.0, 1.0 }, // red green blue alpha
            .unfocused_color = .{ 0.0, 0.0, 1.0, 1.0 },
            .keybinds = std.AutoHashMap(keys.Keybind, i32).init(std.heap.c_allocator),
        };

        try server.renderer.initServer(wl_server);

        _ = try wlr.Compositor.create(server.wl_server, 6, server.renderer);
        _ = try wlr.Subcompositor.create(server.wl_server);
        _ = try wlr.DataDeviceManager.create(server.wl_server);

        server.backend.events.new_output.add(&server.new_output);

        server.xdg_shell.events.new_toplevel.add(&server.new_xdg_toplevel);
        server.xdg_shell.events.new_popup.add(&server.new_xdg_popup);
        server.toplevels.init();

        server.backend.events.new_input.add(&server.new_input);
        server.seat.events.request_set_cursor.add(&server.request_set_cursor);
        server.seat.events.request_set_selection.add(&server.request_set_selection);
        server.keyboards.init();

        server.cursor.attachOutputLayout(server.output_layout);
        try server.cursor_mgr.load(1);
        server.cursor.events.motion.add(&server.cursor_motion);
        server.cursor.events.motion_absolute.add(&server.cursor_motion_absolute);
        server.cursor.events.button.add(&server.cursor_button);
        server.cursor.events.axis.add(&server.cursor_axis);
        server.cursor.events.frame.add(&server.cursor_frame);
    }

    pub fn deinit(server: *Server) void {
        // shut down lua first to not get segmentation error
        lua.lua_close(server.lua_state);

        server.wl_server.destroyClients();

        server.new_input.link.remove();
        server.new_output.link.remove();

        server.new_xdg_toplevel.link.remove();
        server.new_xdg_popup.link.remove();
        server.request_set_cursor.link.remove();
        server.request_set_selection.link.remove();
        server.cursor_motion.link.remove();
        server.cursor_motion_absolute.link.remove();
        server.cursor_button.link.remove();
        server.cursor_axis.link.remove();
        server.cursor_frame.link.remove();
        server.keybinds.deinit();
        server.backend.destroy();
        server.wl_server.destroy();
    }

    pub fn reTile(server: *Server) void {
        var output: ?*wlr.Output = server.output_layout.outputAt(server.cursor.x, server.cursor.y);

        if (output == null) {
            if (server.output_layout.outputs.first()) |layout_output| {

                //const layout_output: *wlr.OutputLayout.Output = @fieldParentPtr("link", first_output_link);
                output = layout_output.output;
            } else {
                return;
            }
        }

        var layout_bound: wlr.Box = undefined;
        _ = server.output_layout.getBox(output, &layout_bound);
        const padding = server.border_width;
        const toplevel_count: i32 = @intCast(server.toplevels.length());

        if (toplevel_count == 0) {
            return;
        }

        const window_height: i32 = @intCast(layout_bound.height - padding * 2);
        // Calculate available width: total width minus left and right padding
        // Each window has border_width on left and right, so we need to account for that
        const available_width: i32 = @intCast(layout_bound.width - padding * 2);
        // Divide available width equally among all windows
        // Each window's total space includes its surface width plus borders on both sides
        const total_space_per_window: i32 = @divTrunc(available_width, toplevel_count);
        // Surface width is total space minus borders on both sides
        const window_width: i32 = total_space_per_window - padding * 2;

        var current_x: i32 = layout_bound.x + padding;

        var it = server.toplevels.link.prev;

        while (it != &server.toplevels.link) {
            const toplevel: *Toplevel = @fieldParentPtr("link", it.?);

            toplevel.x = current_x;
            toplevel.y = layout_bound.y + padding;
            toplevel.scene_tree.node.setPosition(toplevel.x, toplevel.y);

            _ = toplevel.xdg_toplevel.setSize(window_width, window_height);

            // Update border size immediately with the size we just set
            // This ensures the border is visible even before the client commits
            const border_width = server.border_width;
            toplevel.border_node.setSize(window_width + border_width * 2, window_height + border_width * 2);
            toplevel.border_node.node.setPosition(0, 0);
            toplevel.surface_scene_tree.node.setPosition(border_width, border_width);

            // Move to next position: current position + total space (includes borders)
            current_x += total_space_per_window;
            it = it.?.prev;
        }
    }

    fn newOutput(listener: *wl.Listener(*wlr.Output), wlr_output: *wlr.Output) void {
        const server: *Server = @fieldParentPtr("new_output", listener);

        if (!wlr_output.initRender(server.allocator, server.renderer)) return;

        var state = wlr.Output.State.init();
        defer state.finish();

        state.setEnabled(true);
        if (wlr_output.preferredMode()) |mode| {
            state.setMode(mode);
        }
        if (!wlr_output.commitState(&state)) return;

        Output.create(server, wlr_output) catch {
            std.log.err("failed to allocate new output", .{});
            wlr_output.destroy();
            return;
        };
    }

    fn newXdgToplevel(listener: *wl.Listener(*wlr.XdgToplevel), xdg_toplevel: *wlr.XdgToplevel) void {
        const server: *Server = @fieldParentPtr("new_xdg_toplevel", listener);
        const xdg_surface = xdg_toplevel.base;

        // Don't add the toplevel to server.toplevels until it is mapped
        const toplevel = gpa.create(Toplevel) catch {
            std.log.err("failed to allocate new toplevel", .{});
            return;
        };

        // the color and the witdh of the border already set in the server
        const scene_tree = server.scene.tree.createSceneTree() catch {
            gpa.destroy(toplevel);
            std.log.err("failed to allocate new toplevel scene tree", .{});
            return;
        };

        const surface_scene_tree = scene_tree.createSceneXdgSurface(xdg_surface) catch {
            scene_tree.node.destroy();
            gpa.destroy(toplevel);
            std.log.err("failed to allocate new toplevel surface", .{});
            return;
        };

        const border_node = scene_tree.createSceneRect(0, 0, &server.unfocused_color) catch {
            surface_scene_tree.node.destroy();
            scene_tree.node.destroy();
            gpa.destroy(toplevel);
            std.log.err("failed to allocate new toplevel border", .{});
            return;
        };

        border_node.node.lowerToBottom();

        toplevel.* = .{
            .server = server,
            .xdg_toplevel = xdg_toplevel,
            .scene_tree = scene_tree,
            .surface_scene_tree = surface_scene_tree,
            .border_node = border_node,
        };
        toplevel.scene_tree.node.data = toplevel;
        xdg_surface.data = toplevel.surface_scene_tree;

        xdg_surface.surface.events.commit.add(&toplevel.commit);
        xdg_surface.surface.events.map.add(&toplevel.map);
        xdg_surface.surface.events.unmap.add(&toplevel.unmap);
        xdg_toplevel.events.destroy.add(&toplevel.destroy);
        //xdg_toplevel.events.request_move.add(&toplevel.request_move);
        //xdg_toplevel.events.request_resize.add(&toplevel.request_resize);
    }

    fn newXdgPopup(_: *wl.Listener(*wlr.XdgPopup), xdg_popup: *wlr.XdgPopup) void {
        const xdg_surface = xdg_popup.base;

        // These asserts are fine since tinywl.zig doesn't support anything else that can
        // make xdg popups (e.g. layer shell).
        const parent = wlr.XdgSurface.tryFromWlrSurface(xdg_popup.parent.?) orelse return;
        const parent_tree = @as(?*wlr.SceneTree, @ptrCast(@alignCast(parent.data))) orelse {
            // The xdg surface user data could be left null due to allocation failure.
            return;
        };
        const scene_tree = parent_tree.createSceneXdgSurface(xdg_surface) catch {
            std.log.err("failed to allocate xdg popup node", .{});
            return;
        };
        xdg_surface.data = scene_tree;

        const popup = gpa.create(Popup) catch {
            std.log.err("failed to allocate new popup", .{});
            return;
        };
        popup.* = .{
            .xdg_popup = xdg_popup,
        };

        xdg_surface.surface.events.commit.add(&popup.commit);
        xdg_popup.events.destroy.add(&popup.destroy);
    }

    const ViewAtResult = struct {
        toplevel: *Toplevel,
        surface: *wlr.Surface,
        sx: f64,
        sy: f64,
    };

    fn viewAt(server: *Server, lx: f64, ly: f64) ?ViewAtResult {
        var sx: f64 = undefined;
        var sy: f64 = undefined;
        if (server.scene.tree.node.at(lx, ly, &sx, &sy)) |node| {
            if (node.type != .buffer) return null;
            const scene_buffer = wlr.SceneBuffer.fromNode(node);
            const scene_surface = wlr.SceneSurface.tryFromBuffer(scene_buffer) orelse return null;

            var it: ?*wlr.SceneTree = node.parent;
            while (it) |n| : (it = n.node.parent) {
                if (@as(?*Toplevel, @ptrCast(@alignCast(n.node.data)))) |toplevel| {
                    return ViewAtResult{
                        .toplevel = toplevel,
                        .surface = scene_surface.surface,
                        .sx = sx,
                        .sy = sy,
                    };
                }
            }
        }
        return null;
    }

    pub fn focusView(server: *Server, toplevel: *Toplevel, surface: *wlr.Surface) void {
        if (server.seat.keyboard_state.focused_surface) |previous_surface| {
            if (previous_surface == surface) return;
            if (wlr.XdgSurface.tryFromWlrSurface(previous_surface)) |xdg_surface| {
                _ = xdg_surface.role_data.toplevel.?.setActivated(false);

                if (xdg_surface.data) |data_ptr| {
                    const scene_tree = @as(*wlr.SceneTree, @ptrCast(@alignCast(data_ptr)));
                    if (scene_tree.node.parent) |container_node| {
                        if (container_node.node.data) |container_data_ptr| {
                            if (@as(?*Toplevel, @ptrCast(@alignCast(container_data_ptr)))) |prev_toplevel| {
                                prev_toplevel.border_node.setColor(&server.unfocused_color);
                            }
                        }
                    }
                }
            }
        }

        toplevel.scene_tree.node.raiseToTop();
        //toplevel.link.remove();
        //server.toplevels.prepend(toplevel);

        _ = toplevel.xdg_toplevel.setActivated(true);
        toplevel.border_node.setColor(&server.focused_color);

        const wlr_keyboard = server.seat.getKeyboard() orelse return;
        server.seat.keyboardNotifyEnter(
            surface,
            wlr_keyboard.keycodes[0..wlr_keyboard.num_keycodes],
            &wlr_keyboard.modifiers,
        );
    }

    fn newInput(listener: *wl.Listener(*wlr.InputDevice), device: *wlr.InputDevice) void {
        const server: *Server = @fieldParentPtr("new_input", listener);
        switch (device.type) {
            .keyboard => Keyboard.create(server, device) catch |err| {
                std.log.err("failed to create keyboard: {}", .{err});
                return;
            },
            .pointer => server.cursor.attachInputDevice(device),
            else => {},
        }

        server.seat.setCapabilities(.{
            .pointer = true,
            .keyboard = server.keyboards.length() > 0,
        });
    }

    fn requestSetCursor(
        listener: *wl.Listener(*wlr.Seat.event.RequestSetCursor),
        event: *wlr.Seat.event.RequestSetCursor,
    ) void {
        const server: *Server = @fieldParentPtr("request_set_cursor", listener);
        if (event.seat_client == server.seat.pointer_state.focused_client)
            server.cursor.setSurface(event.surface, event.hotspot_x, event.hotspot_y);
    }

    fn requestSetSelection(
        listener: *wl.Listener(*wlr.Seat.event.RequestSetSelection),
        event: *wlr.Seat.event.RequestSetSelection,
    ) void {
        const server: *Server = @fieldParentPtr("request_set_selection", listener);
        server.seat.setSelection(event.source, event.serial);
    }

    fn cursorMotion(
        listener: *wl.Listener(*wlr.Pointer.event.Motion),
        event: *wlr.Pointer.event.Motion,
    ) void {
        const server: *Server = @fieldParentPtr("cursor_motion", listener);
        server.cursor.move(event.device, event.delta_x, event.delta_y);
        server.processCursorMotion(event.time_msec);
    }

    fn cursorMotionAbsolute(
        listener: *wl.Listener(*wlr.Pointer.event.MotionAbsolute),
        event: *wlr.Pointer.event.MotionAbsolute,
    ) void {
        const server: *Server = @fieldParentPtr("cursor_motion_absolute", listener);
        server.cursor.warpAbsolute(event.device, event.x, event.y);
        server.processCursorMotion(event.time_msec);
    }

    fn processCursorMotion(server: *Server, time_msec: u32) void {
        switch (server.cursor_mode) {
            .passthrough => if (server.viewAt(server.cursor.x, server.cursor.y)) |res| {
                server.seat.pointerNotifyEnter(res.surface, res.sx, res.sy);
                server.seat.pointerNotifyMotion(time_msec, res.sx, res.sy);
            } else {
                server.cursor.setXcursor(server.cursor_mgr, "default");
                server.seat.pointerClearFocus();
            },
            .move => {
                const toplevel = server.grabbed_view.?;
                toplevel.x = @as(i32, @intFromFloat(server.cursor.x - server.grab_x));
                toplevel.y = @as(i32, @intFromFloat(server.cursor.y - server.grab_y));

                const surface_state = toplevel.xdg_toplevel.base.geometry;

                const total_width = surface_state.width + server.border_width * 2;
                const total_height = surface_state.height + server.border_width * 2;

                var layout_bounds: wlr.Box = undefined;
                _ = server.output_layout.getBox(null, &layout_bounds);

                toplevel.x = @max(layout_bounds.x, toplevel.x);

                toplevel.y = @max(layout_bounds.y, toplevel.y);

                toplevel.x = @min(layout_bounds.x + layout_bounds.width - total_width, toplevel.x);

                toplevel.y = @min(layout_bounds.y + layout_bounds.height - total_height, toplevel.y);

                toplevel.scene_tree.node.setPosition(toplevel.x, toplevel.y);
            },
            .resize => {
                const toplevel = server.grabbed_view.?;
                const border_x = @as(i32, @intFromFloat(server.cursor.x - server.grab_x));
                const border_y = @as(i32, @intFromFloat(server.cursor.y - server.grab_y));

                var new_left = server.grab_box.x;
                var new_right = server.grab_box.x + server.grab_box.width;
                var new_top = server.grab_box.y;
                var new_bottom = server.grab_box.y + server.grab_box.height;

                if (server.resize_edges.top) {
                    new_top = border_y;
                    if (new_top >= new_bottom)
                        new_top = new_bottom - 1;
                } else if (server.resize_edges.bottom) {
                    new_bottom = border_y;
                    if (new_bottom <= new_top)
                        new_bottom = new_top + 1;
                }

                if (server.resize_edges.left) {
                    new_left = border_x;
                    if (new_left >= new_right)
                        new_left = new_right - 1;
                } else if (server.resize_edges.right) {
                    new_right = border_x;
                    if (new_right <= new_left)
                        new_right = new_left + 1;
                }

                toplevel.x = new_left - toplevel.xdg_toplevel.base.geometry.x;
                toplevel.y = new_top - toplevel.xdg_toplevel.base.geometry.y;
                toplevel.scene_tree.node.setPosition(toplevel.x, toplevel.y);

                const new_width = new_right - new_left;
                const new_height = new_bottom - new_top;
                _ = toplevel.xdg_toplevel.setSize(new_width, new_height);
            },
        }
    }

    fn cursorButton(
        listener: *wl.Listener(*wlr.Pointer.event.Button),
        event: *wlr.Pointer.event.Button,
    ) void {
        const server: *Server = @fieldParentPtr("cursor_button", listener);
        _ = server.seat.pointerNotifyButton(event.time_msec, event.button, event.state);

        const is_lmb = (event.button == 272);

        if (event.state == .released) {
            if (is_lmb and server.cursor_mode == .move) {
                server.cursor_mode = .passthrough;
                server.grabbed_view = null;
            }
        } else if (server.viewAt(server.cursor.x, server.cursor.y)) |res| {
            server.focusView(res.toplevel, res.surface);
            var alt_pressed = false;
            if (server.seat.getKeyboard()) |wlr_keyboard| {
                alt_pressed = wlr_keyboard.getModifiers().alt;
            }

            if (alt_pressed and is_lmb) {
                server.grabbed_view = res.toplevel;
                server.cursor_mode = .move;
                server.grab_x = server.cursor.x - @as(f64, @floatFromInt(res.toplevel.x));
                server.grab_y = server.cursor.y - @as(f64, @floatFromInt(res.toplevel.y));
                return;
            }
        }
    }

    fn cursorAxis(
        listener: *wl.Listener(*wlr.Pointer.event.Axis),
        event: *wlr.Pointer.event.Axis,
    ) void {
        const server: *Server = @fieldParentPtr("cursor_axis", listener);
        server.seat.pointerNotifyAxis(
            event.time_msec,
            event.orientation,
            event.delta,
            event.delta_discrete,
            event.source,
            event.relative_direction,
        );
    }

    fn cursorFrame(listener: *wl.Listener(*wlr.Cursor), _: *wlr.Cursor) void {
        const server: *Server = @fieldParentPtr("cursor_frame", listener);
        server.seat.pointerNotifyFrame();
    }

    /// Assumes the modifier used for compositor keybinds is pressed
    /// Returns true if the key was handled
    ///
    pub fn executeKeybind(server: *Server, modifiers: keys.ModMask, keysym: xkb.Keysym) bool {
        const bind = keys.Keybind{ .modifiers = modifiers, .keysym = keysym };

        // Check if the user's keystroke exists in our map
        if (server.keybinds.get(bind)) |registry_id| {
            // 1. Pull the function out of the Lua Registry and onto the stack
            _ = lua.lua_rawgeti(server.lua_state, lua.LUA_REGISTRYINDEX, registry_id);

            // 2. Call the function (0 arguments, 0 returns)
            if (lua.lua_pcallk(server.lua_state, 0, 0, 0, 0, null) != lua.LUA_OK) {
                const err_msg = lua.lua_tolstring(server.lua_state, -1, null);
                std.log.err("Keybind execution failed: {s}", .{std.mem.span(err_msg)});
                lua.lua_pop(server.lua_state, 1); // Cleanup the error from the stack
            }
            return true; // We handled it! Don't pass this key to Kitty/Browser.
        }

        return false;
    }

    pub fn spawnProgram(server: *Server, cmd: []const u8) !void {
        // Create an arena allocator just for the lifespan of this spawn command
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const allocator = arena.allocator();

        var env_map = try std.process.getEnvMap(allocator);
        try env_map.put("WAYLAND_DISPLAY", server.socket_name);

        var child = std.process.Child.init(&[_][]const u8{ "/bin/sh", "-c", cmd }, allocator);
        child.env_map = &env_map;

        // Spawn the process (it runs asynchronously)
        try child.spawn();
    }
};
