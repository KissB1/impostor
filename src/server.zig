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

    // different sceen trees for different purpose windows, like the background
    bg_tree: *wlr.SceneTree,
    bottom_tree: *wlr.SceneTree,
    window_tree: *wlr.SceneTree,
    top_tree: *wlr.SceneTree,
    overlay_tree: *wlr.SceneTree,

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

    // layer shell for waybar and apps that needs to know where to go and stay,
    layer_shell: ?*wlr.LayerShellV1,
    layer_shell_new_surface: wl.Listener(*wlr.LayerSurfaceV1) = .init(handleLayerShellNewSurface),

    layer_surfaces: wl.list.Head(LayerSurface, .link) = undefined,
    // usable area moved to output.zig since it is per output, not global

    // The drop shadow indicator
    drop_preview_node: *wlr.SceneRect = undefined,
    socket_name: []const u8 = undefined,

    // border
    border_width: i32,
    focused_color: [4]f32,
    unfocused_color: [4]f32,

    // Gaps
    inner_gap: i32 = 10,
    outer_gap: i32 = 10,

    //keybind hashmap
    keybinds: std.AutoHashMap(keys.Keybind, keys.BindAction),
    current_key_state: u32 = 0,

    //mousebind hashmap
    mousebinds: std.AutoHashMap(keys.MouseBind, keys.MouseAction),

    // Workspaces moved to output.zig

    // lua state, this is the main lua pointer, akin to the file pointer when opening a file.
    lua_state: *lua.lua_State,

    pub fn init(server: *Server) !void {
        // Lua must be initialized first so the client can connect to the server at startup

        const L = lua.luaL_newstate() orelse return error.LuaInitFailed;
        lua.luaL_openlibs(L);
        lua_api.registerAll(L, server);

        const core_lua = @embedFile("lua/core.lua");
        // Use loadbuffer since @embedFile gives us a safe slice of memory
        if (lua.luaL_loadbufferx(L, core_lua.ptr, core_lua.len, "core.lua", null) != lua.LUA_OK or
            lua.lua_pcallk(L, 0, 0, 0, 0, null) != lua.LUA_OK)
        {
            const err_msg = lua.lua_tolstring(L, -1, null);
            std.log.err("Failed to inject core Lua: {s}", .{std.mem.span(err_msg)});
            lua.lua_pop(L, 1);
        }

        const wl_server = try wl.Server.create();
        const loop = wl_server.getEventLoop();
        const backend = try wlr.Backend.autocreate(loop, null);
        const renderer = try wlr.Renderer.autocreate(backend);
        const output_layout = try wlr.OutputLayout.create(wl_server);
        const scene = try wlr.Scene.create();
        // 1. Background (Wallpapers)
        const bg_tree = try scene.tree.createSceneTree();
        // 2. Bottom (Desktop widgets)
        const bottom_tree = try scene.tree.createSceneTree();
        // 3. Normal Windows (Kitty, Firefox)
        const window_tree = try scene.tree.createSceneTree();
        // 4. Top (Waybar)
        const top_tree = try scene.tree.createSceneTree();
        // 5. Overlay (Fuzzel, Notifications)
        const overlay_tree = try scene.tree.createSceneTree();
        server.* = .{
            .wl_server = wl_server,
            .lua_state = L,
            .backend = backend,
            .renderer = renderer,
            .allocator = try wlr.Allocator.autocreate(backend, renderer),
            .scene = scene,
            .bg_tree = bg_tree,
            .bottom_tree = bottom_tree,
            .window_tree = window_tree,
            .top_tree = top_tree,
            .overlay_tree = overlay_tree,
            .output_layout = output_layout,
            .scene_output_layout = try scene.attachOutputLayout(output_layout),
            .xdg_shell = try wlr.XdgShell.create(wl_server, 3),
            .layer_shell = try wlr.LayerShellV1.create(wl_server, 4),
            .seat = try wlr.Seat.create(wl_server, "default"),
            .cursor = try wlr.Cursor.create(),
            .cursor_mgr = try wlr.XcursorManager.create(null, 24),
            .border_width = 4,
            .focused_color = .{ 1.0, 0.0, 0.0, 1.0 }, // red green blue alpha
            .unfocused_color = .{ 0.0, 0.0, 1.0, 1.0 },
            .keybinds = std.AutoHashMap(keys.Keybind, keys.BindAction).init(std.heap.c_allocator),
            .mousebinds = std.AutoHashMap(keys.MouseBind, keys.MouseAction).init(std.heap.c_allocator),
        };

        try server.renderer.initServer(wl_server);

        const bg_color = [4]f32{ 0.118, 0.118, 0.180, 1.0 };

        const bg_node = server.scene.tree.createSceneRect(9999, 9999, &bg_color) catch {
            std.log.err("failed to create background node", .{});
            return;
        };

        bg_node.node.lowerToBottom();

        // Create a bright, semi-transparent preview shadow (R, G, B, Alpha)
        const preview_color = [4]f32{ 0.2, 0.6, 1.0, 0.4 };
        server.drop_preview_node = try server.scene.tree.createSceneRect(0, 0, &preview_color);
        server.drop_preview_node.node.setEnabled(false); // Hidden by default

        _ = try wlr.Compositor.create(server.wl_server, 6, server.renderer);
        _ = try wlr.Subcompositor.create(server.wl_server);
        _ = try wlr.DataDeviceManager.create(server.wl_server);

        server.backend.events.new_output.add(&server.new_output);

        server.xdg_shell.events.new_toplevel.add(&server.new_xdg_toplevel);
        server.xdg_shell.events.new_popup.add(&server.new_xdg_popup);
        server.layer_shell.?.events.new_surface.add(&server.layer_shell_new_surface);

        // 1. Gives Waybar your monitor names and geometry
        _ = try wlr.XdgOutputManagerV1.create(server.wl_server, server.output_layout);

        // 2. Allows Kitty to politely ask for focus
        _ = try wlr.XdgActivationV1.create(server.wl_server);

        server.toplevels.init();
        server.layer_surfaces.init();

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
        server.mousebinds.deinit();

        server.backend.destroy();
        server.wl_server.destroy();
    }

    pub fn reTile(server: *Server) void {
        // ==========================================================
        // PASS 1 & 2: LOOP THROUGH EVERY MONITOR INDEPENDENTLY
        // ==========================================================
        var it_out = server.output_layout.outputs.link.next;
        while (it_out != &server.output_layout.outputs.link) : (it_out = it_out.?.next) {
            const layout_output: *wlr.OutputLayout.Output = @fieldParentPtr("link", it_out.?);
            const wlr_output = layout_output.output;

            // Get the specific data for THIS monitor
            const out_struct = @as(*Output, @ptrCast(@alignCast(wlr_output.data.?)));
            const current_tags = out_struct.current_tags;

            // --- PASS 1: The Filter ---
            var it_top = server.toplevels.link.prev;
            while (it_top != &server.toplevels.link) : (it_top = it_top.?.prev) {
                const toplevel: *Toplevel = @fieldParentPtr("link", it_top.?);

                // ONLY touch windows that belong to this specific monitor!
                if (toplevel.output == wlr_output) {
                    const is_visible = (toplevel.tags & current_tags) != 0;
                    toplevel.scene_tree.node.setEnabled(is_visible);
                }
            }

            // --- PASS 2: Let Lua do the Math ---
            const L = server.lua_state;
            _ = lua.lua_getglobal(L, "wm");
            _ = lua.lua_getfield(L, -1, "on_tile");

            if (lua.lua_isfunction(L, -1)) {
                lua.lua_newtable(L);
                var array_index: i32 = 1;

                var it_lua = server.toplevels.link.prev;
                while (it_lua != &server.toplevels.link) : (it_lua = it_lua.?.prev) {
                    const toplevel: *Toplevel = @fieldParentPtr("link", it_lua.?);

                    // ONLY give Lua the windows for this monitor's active tag
                    if (toplevel.output == wlr_output and (toplevel.tags & current_tags) != 0) {
                        lua_api.push_client(L, toplevel);
                        lua.lua_rawseti(L, -2, array_index);
                        array_index += 1;
                    }
                }

                // Grab the safe zone FOR THIS MONITOR
                var bounds = out_struct.usable_area;
                if (bounds.width == 0) {
                    _ = server.output_layout.getBox(wlr_output, &bounds);
                }

                lua.lua_pushinteger(L, bounds.x);
                lua.lua_pushinteger(L, bounds.y);
                lua.lua_pushinteger(L, bounds.width);
                lua.lua_pushinteger(L, bounds.height);
                lua.lua_pushinteger(L, current_tags);

                if (lua.lua_pcallk(L, 6, 0, 0, 0, null) != lua.LUA_OK) {
                    const err_msg = lua.lua_tolstring(L, -1, null);
                    std.log.err("Lua on_tile Error: {s}", .{std.mem.span(err_msg)});
                    lua.lua_pop(L, 1);
                }
            } else {
                lua.lua_pop(L, 1);
            }
            lua.lua_pop(L, 1); // Pop 'wm' table
        }

        // ==========================================================
        // PASS 3: FOCUS MANAGEMENT (Which monitor is the mouse on?)
        // ==========================================================
        // --- NEW: The Fuzzel Protector ---
        // Check if a Layer Shell app currently owns the keyboard!
        var is_layer_focused = false;
        var it_ls = server.layer_surfaces.link.next;
        while (it_ls != &server.layer_surfaces.link) : (it_ls = it_ls.?.next) {
            const ls: *LayerSurface = @fieldParentPtr("link", it_ls.?);
            if (ls.layer_surface.surface == server.seat.keyboard_state.focused_surface) {
                is_layer_focused = true;
                break;
            }
        }

        // Only let reTile touch the keyboard if Fuzzel ISN'T using it!
        if (!is_layer_focused) {
            var cursor_out = server.output_layout.outputAt(server.cursor.x, server.cursor.y);
            if (cursor_out == null) {
                if (server.output_layout.outputs.first()) |lo| {
                    cursor_out = lo.output;
                }
            }

            var found_focus = false;
            if (cursor_out) |c_out| {
                const cursor_out_struct = @as(*Output, @ptrCast(@alignCast(c_out.data.?)));

                var it_focus = server.toplevels.link.prev;
                while (it_focus != &server.toplevels.link) : (it_focus = it_focus.?.prev) {
                    const target: *Toplevel = @fieldParentPtr("link", it_focus.?);

                    if (target.output == c_out and (target.tags & cursor_out_struct.current_tags) != 0) {
                        server.focusView(target, target.xdg_toplevel.base.surface);
                        found_focus = true;
                        break;
                    }
                }
            }

            if (!found_focus) {
                server.seat.keyboardNotifyClearFocus();
            }
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

        // Automatically arrange monitors side-by-side from left to right!
        _ = server.output_layout.addAuto(wlr_output) catch return;

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
        const scene_tree = server.window_tree.createSceneTree() catch {
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

        // Figure out which monitor the mouse is on
        var active_output = server.output_layout.outputAt(server.cursor.x, server.cursor.y);
        if (active_output == null) {
            active_output = server.output_layout.outputs.first().?.output;
        }

        // Grab our custom Output struct so we know what tag this monitor is currently looking at
        // If data is null, gracefully log the error and clean up memory instead of crashing!
        const out_data = active_output.?.data orelse {
            std.log.err("CRITICAL: Monitor data is null! Missing wlr_output.data assignment.", .{});
            gpa.destroy(toplevel);
            scene_tree.node.destroy();
            return;
        };
        const out_struct = @as(*Output, @ptrCast(@alignCast(out_data)));

        toplevel.* = .{
            .server = server,
            .xdg_toplevel = xdg_toplevel,
            .scene_tree = scene_tree,
            .surface_scene_tree = surface_scene_tree,
            .border_node = border_node,
            // Assign the output and the tags
            .output = active_output.?,
            .tags = out_struct.current_tags,
        };
        toplevel.scene_tree.node.data = toplevel;
        xdg_surface.data = toplevel.surface_scene_tree;

        xdg_surface.surface.events.commit.add(&toplevel.commit);
        xdg_surface.surface.events.map.add(&toplevel.map);
        xdg_surface.surface.events.unmap.add(&toplevel.unmap);
        xdg_toplevel.events.destroy.add(&toplevel.destroy);
        xdg_toplevel.events.request_move.add(&toplevel.request_move);
        xdg_toplevel.events.request_resize.add(&toplevel.request_resize);

        // for the specific workspaces, Like firefox always on workspace 4.
        xdg_toplevel.events.set_title.add(&toplevel.set_title);
        xdg_toplevel.events.set_app_id.add(&toplevel.set_app_id);
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

                // for drag and drop between monitors.
                if (server.output_layout.outputAt(server.cursor.x, server.cursor.y)) |current_out| {
                    if (toplevel.output != current_out) {
                        // The mouse crossed the bezel! Update the window's passport.
                        toplevel.output = current_out;

                        //const Output = @import("../output/output.zig").Output; // ensure this is imported!
                        const out_struct = @as(*Output, @ptrCast(@alignCast(current_out.data.?)));

                        // Assign it to the new monitor's active workspace
                        toplevel.tags = out_struct.current_tags;
                    }
                }
                // ==========================================

                // --- UPDATE THE DROP PREVIEW SHADOW ---
                var hovered_target: ?*Toplevel = null;

                // Get the monitor the mouse is currently on
                var current_out = server.output_layout.outputAt(server.cursor.x, server.cursor.y);
                if (current_out == null) {
                    if (server.output_layout.outputs.first()) |lo| {
                        current_out = lo.output;
                    }
                }

                var it = server.toplevels.link.prev;

                while (it != &server.toplevels.link) : (it = it.?.prev) {
                    const check_top: *Toplevel = @fieldParentPtr("link", it.?);
                    if (check_top == toplevel or check_top.output != current_out.? or (check_top.tags & server.getActiveTags()) == 0) continue;

                    const geom = check_top.xdg_toplevel.base.geometry;
                    const top_x = @as(f64, @floatFromInt(check_top.x));
                    const top_y = @as(f64, @floatFromInt(check_top.y));

                    const top_w = @as(f64, @floatFromInt(geom.width + (server.border_width * 2)));
                    const top_h = @as(f64, @floatFromInt(geom.height + (server.border_width * 2)));

                    // === THE X-RAY LOG ===
                    // This prints every single frame while dragging, showing us exactly
                    // where the WM thinks the cursor and the target windows are.
                    std.log.info("X-Ray -> Cursor: {d},{d} | Target Box: X:{d} Y:{d} W:{d} H:{d}", .{ server.cursor.x, server.cursor.y, top_x, top_y, top_w, top_h });

                    if (server.cursor.x >= top_x and server.cursor.x <= top_x + top_w and
                        server.cursor.y >= top_y and server.cursor.y <= top_y + top_h)
                    {
                        hovered_target = check_top;
                        break;
                    }
                }

                if (hovered_target) |target| {
                    server.drop_preview_node.node.setEnabled(true);
                    server.drop_preview_node.node.raiseToTop(); // Force to front

                    const t_geom = target.xdg_toplevel.base.geometry;
                    const t_w = t_geom.width + (server.border_width * 2);
                    const t_h = t_geom.height + (server.border_width * 2);
                    const target_mid_x = @as(f64, @floatFromInt(target.x)) + (@as(f64, @floatFromInt(t_w)) / 2.0);
                    const half_width = @divTrunc(t_w, 2);

                    // === DEBUG LOG ===
                    // If you don't see this in your terminal when dragging over a window,
                    // the hit-detection math above is failing!
                    std.log.info("SHADOW ACTIVE: Target Mid X is {d}, Cursor X is {d}", .{ target_mid_x, server.cursor.x });

                    if (server.cursor.x < target_mid_x) {
                        server.drop_preview_node.setSize(half_width, t_h);
                        server.drop_preview_node.node.setPosition(target.x, target.y);
                    } else {
                        server.drop_preview_node.setSize(half_width, t_h);
                        server.drop_preview_node.node.setPosition(target.x + half_width, target.y);
                    }
                } else {
                    server.drop_preview_node.node.setEnabled(false);
                }
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

        // 1. Get current keyboard modifiers
        var active_mods = keys.ModMask{};
        if (server.seat.getKeyboard()) |wlr_keyboard| {
            const mods = wlr_keyboard.getModifiers();
            active_mods = .{
                .shift = mods.shift,
                .ctrl = mods.ctrl,
                .alt = mods.alt,
                .super = mods.logo,
            };
        }

        // 2. Handle Mouse Release (Dropping)
        if (event.state == .released) {
            if (server.cursor_mode == .move) {
                server.drop_preview_node.node.setEnabled(false);
                if (server.grabbed_view) |grabbed| {
                    // Manual hit-detection: Find the window underneath the cursor
                    // that is NOT the grabbed window.
                    var target: ?*Toplevel = null;
                    var it = server.toplevels.link.prev;

                    // 1. MATCH THE SHADOW'S HITBOX MATH
                    while (it != &server.toplevels.link) : (it = it.?.prev) {
                        const check_top: *Toplevel = @fieldParentPtr("link", it.?);
                        if (check_top == grabbed or (check_top.tags & server.getActiveTags()) == 0) continue;

                        const geom = check_top.xdg_toplevel.base.geometry;
                        const top_x = @as(f64, @floatFromInt(check_top.x));
                        const top_y = @as(f64, @floatFromInt(check_top.y));
                        // MUST include borders, just like processCursorMotion!
                        const top_w = @as(f64, @floatFromInt(geom.width + (server.border_width * 2)));
                        const top_h = @as(f64, @floatFromInt(geom.height + (server.border_width * 2)));

                        if (server.cursor.x >= top_x and server.cursor.x <= top_x + top_w and
                            server.cursor.y >= top_y and server.cursor.y <= top_y + top_h)
                        {
                            target = check_top;
                            break; // Found our drop target!
                        }
                    }

                    // 2. MATCH THE SHADOW'S CENTER MATH AND FIX LIST INSERTION
                    if (target) |t| {
                        grabbed.link.remove();

                        const t_geom = t.xdg_toplevel.base.geometry;
                        const t_w = t_geom.width + (server.border_width * 2);
                        const target_mid_x = @as(f64, @floatFromInt(t.x)) + (@as(f64, @floatFromInt(t_w)) / 2.0);

                        if (server.cursor.x < target_mid_x) {
                            // Cursor is on the LEFT half.
                            // Because reTile iterates backwards, inserting AFTER forces it left.
                            t.link.insert(&grabbed.link);
                        } else {
                            // Cursor is on the RIGHT half.
                            // Inserting BEFORE the target forces it right.
                            t.link.prev.?.insert(&grabbed.link);
                        }
                    }
                }
                server.cursor_mode = .passthrough;
                server.grabbed_view = null;
                server.reTile();
            } else if (server.cursor_mode == .resize) {
                server.cursor_mode = .passthrough;
                server.grabbed_view = null;
            }

            _ = server.seat.pointerNotifyButton(event.time_msec, event.button, event.state);
            return;
        }

        // 3. Handle Mouse Press (Grabbing)
        if (server.viewAt(server.cursor.x, server.cursor.y)) |res| {
            server.focusView(res.toplevel, res.surface);

            // CHECK THE LUA HASHMAP!
            const bind_to_check = keys.MouseBind{ .modifiers = active_mods, .button = event.button };
            if (server.mousebinds.get(bind_to_check)) |action| {
                server.grabbed_view = res.toplevel;

                switch (action) {
                    .move => {
                        server.cursor_mode = .move;
                        // Inside your interactive move logic in cursorButton:
                        server.grab_x = server.cursor.x - @as(f64, @floatFromInt(server.grabbed_view.?.scene_tree.node.x));
                        server.grab_y = server.cursor.y - @as(f64, @floatFromInt(server.grabbed_view.?.scene_tree.node.y));
                    },
                    .resize => {
                        server.cursor_mode = .resize;
                        // Basic resize logic (you can refine edges later)
                        const box = res.toplevel.xdg_toplevel.base.geometry;
                        server.grab_x = server.cursor.x - @as(f64, @floatFromInt(res.toplevel.x + box.x + box.width));
                        server.grab_y = server.cursor.y - @as(f64, @floatFromInt(res.toplevel.y + box.y + box.height));
                    },
                }

                // Swallow the click! The WM handled it.
                return;
            }
        }

        // 4. Pass regular clicks to the app
        _ = server.seat.pointerNotifyButton(event.time_msec, event.button, event.state);
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

    // Returns true if the key was handled
    pub fn executeKeybind(server: *Server, modifiers: keys.ModMask, keysym: xkb.Keysym) bool {
        var search_mods = modifiers;
        var search_sym_int: u32 = @intFromEnum(keysym);

        // --- THE VIM-LEADER HACK ---
        // If you physically tap a modifier key (like Alt_L), wlroots instantly activates
        // the modifier bit. To match our purely sequential config (which has no modifiers),
        // we strip the bit for the key currently being pressed.
        switch (@intFromEnum(keysym)) {
            xkb.Keysym.Alt_L, xkb.Keysym.Alt_R => search_mods.alt = false,
            xkb.Keysym.Super_L, xkb.Keysym.Super_R => search_mods.super = false,
            xkb.Keysym.Control_L, xkb.Keysym.Control_R => search_mods.ctrl = false,
            xkb.Keysym.Shift_L, xkb.Keysym.Shift_R => search_mods.shift = false,
            else => {},
        }
        // --- 2. THE NORMALIZATION FUNNEL ---
        // Funnel all Right-sided physical keys into Left-sided lookups
        // * NOTE: We are intentionally squashing Right modifiers into Left modifiers here.
        // * If an app breaks because it needs Right-Shift specifically, look here first.
        switch (search_sym_int) {
            xkb.Keysym.Super_R => search_sym_int = xkb.Keysym.Super_L,
            xkb.Keysym.Alt_R => search_sym_int = xkb.Keysym.Alt_L,
            xkb.Keysym.Shift_R => search_sym_int = xkb.Keysym.Shift_L,
            xkb.Keysym.Control_R => search_sym_int = xkb.Keysym.Control_L,
            else => {},
        }

        const bind = keys.Keybind{ .state = server.current_key_state, .modifiers = search_mods, .keysym = keysym };

        //std.log.info("[FSM-EXEC] Looking up -> State:{d} | Mods[S:{}, A:{}, C:{}, Sh:{}] | Keysym:{d}", .{ server.current_key_state, search_mods.super, search_mods.alt, search_mods.ctrl, search_mods.shift, keysym });

        if (server.keybinds.get(bind)) |action| {
            //std.log.info("[FSM-EXEC] *** MATCH FOUND! ***", .{});
            switch (action) {
                .next_state => |next_id| {
                    server.current_key_state = next_id; // Move deeper into the tree
                    //std.log.info("Entered Chord State: {d}", .{next_id});
                },
                .exec_lua => |registry_id| {
                    server.current_key_state = 0; // Reset back to root instantly
                    _ = lua.lua_rawgeti(server.lua_state, lua.LUA_REGISTRYINDEX, registry_id);
                    if (lua.lua_pcallk(server.lua_state, 0, 0, 0, 0, null) != lua.LUA_OK) {
                        const err_msg = lua.lua_tolstring(server.lua_state, -1, null);
                        std.log.err("Keybind execution failed: {s}", .{std.mem.span(err_msg)});
                        lua.lua_pop(server.lua_state, 1);
                    }
                },
            }
            return true;
        }

        // Cancel sequence on invalid keypress
        const sym_int = @intFromEnum(keysym);
        if (server.current_key_state != 0 and
            sym_int != xkb.Keysym.Shift_L and sym_int != xkb.Keysym.Shift_R and
            sym_int != xkb.Keysym.Control_L and sym_int != xkb.Keysym.Control_R and
            sym_int != xkb.Keysym.Alt_L and sym_int != xkb.Keysym.Alt_R and
            sym_int != xkb.Keysym.Super_L and sym_int != xkb.Keysym.Super_R)
        {
            //std.log.warn("[FSM-EXEC] MISS! Invalid key pressed in State {d}. Resetting to State 0.", .{server.current_key_state});
            server.current_key_state = 0;
            return true;
        }

        return false;
    }

    fn handleLayerShellNewSurface(listener: *wl.Listener(*wlr.LayerSurfaceV1), layer_surface: *wlr.LayerSurfaceV1) void {
        const server: *Server = @fieldParentPtr("layer_shell_new_surface", listener);

        std.log.info("Drawing Layer Shell App: {s}", .{layer_surface.namespace});

        // 1. Assign it to your main monitor
        if (layer_surface.output == null) {
            if (server.output_layout.outputs.first()) |layout_output| {
                layer_surface.output = layout_output.output;
            } else {
                return;
            }
        }

        // 2. Allocate our new wrapper struct
        const ls = gpa.create(LayerSurface) catch {
            std.log.err("Failed to allocate LayerSurface", .{});
            return;
        };

        // Read the requested layer and route it!
        const target_tree = switch (layer_surface.pending.layer) {
            .background => server.bg_tree,
            .bottom => server.bottom_tree,
            .top => server.top_tree,
            .overlay => server.overlay_tree,
            else => server.top_tree,
        };

        // 3. Add Waybar to the Scene Graph
        const scene_layer = target_tree.createSceneLayerSurfaceV1(layer_surface) catch {
            gpa.destroy(ls);
            std.log.err("Failed to create SceneLayerSurfaceV1", .{});
            return;
        };

        // 4. Fill in the struct
        ls.* = .{
            .server = server,
            .layer_surface = layer_surface,
            .scene_layer = scene_layer,
        };

        server.layer_surfaces.append(ls);

        // 5. Hook up the listeners (This is what prevents the crash!)
        layer_surface.surface.events.commit.add(&ls.commit);
        layer_surface.events.destroy.add(&ls.destroy);
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

    pub fn arrangeLayers(server: *Server, output: *wlr.Output) void {
        var full_area: wlr.Box = undefined;
        _ = server.output_layout.getBox(output, &full_area);

        var usable_area = full_area;

        // Loop through EVERY active bar/dock and shrink the usable_area step-by-step
        var it = server.layer_surfaces.link.next;
        while (it != &server.layer_surfaces.link) : (it = it.?.next) {
            const ls: *LayerSurface = @fieldParentPtr("link", it.?);

            // STRICT SECURITY: Only configure if it's on this monitor AND fully initialized!
            if (ls.layer_surface.output == output and ls.layer_surface.initialized) {
                ls.scene_layer.configure(&full_area, &usable_area);
            }
        }

        // Now save the perfectly calculated safe zone and tell Lua!
        if (output.data) |data_ptr| {
            const out = @as(*Output, @ptrCast(@alignCast(data_ptr)));
            out.usable_area = usable_area;
        }
        server.reTile();
    }
    pub fn getActiveTags(server: *Server) u32 {
        // 1. Where is the mouse?
        var out = server.output_layout.outputAt(server.cursor.x, server.cursor.y);
        if (out == null) {
            // Fallback to the first monitor
            if (server.output_layout.outputs.first()) |lo| {
                out = lo.output;
            } else {
                return 1; // Failsafe: return tag 1
            }
        }

        // 2. Return that specific monitor's tag!
        if (out.?.data) |data| {
            const out_struct = @as(*Output, @ptrCast(@alignCast(data)));
            return out_struct.current_tags;
        }

        return 1;
    }
};
pub const LayerSurface = struct {
    server: *Server,
    layer_surface: *wlr.LayerSurfaceV1,
    scene_layer: *wlr.SceneLayerSurfaceV1,

    link: wl.list.Link = undefined,

    commit: wl.Listener(*wlr.Surface) = .init(handleCommit),
    destroy: wl.Listener(*wlr.LayerSurfaceV1) = .init(handleDestroy),

    fn handleCommit(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
        const self: *LayerSurface = @fieldParentPtr("commit", listener);

        // If Waybar is fully loaded and ready, tell the layout engine to run!
        // because probably waybanr says when started that its dimensions are 0x0 then loads
        // the config which tells how big it should be....
        // so the resize of the usable space needs to happen in the commit, not in the new layershell
        if (self.layer_surface.initialized) {
            self.server.arrangeLayers(self.layer_surface.output.?);
        }

        // If Fuzzel asks for the keyboard, we must explicitly hand it over!
        if (self.layer_surface.current.keyboard_interactive != .none) {

            // Only send the focus event if it doesn't already have it
            if (self.server.seat.keyboard_state.focused_surface != self.layer_surface.surface) {
                if (self.server.seat.getKeyboard()) |wlr_keyboard| {
                    self.server.seat.keyboardNotifyEnter(
                        self.layer_surface.surface,
                        wlr_keyboard.keycodes[0..wlr_keyboard.num_keycodes],
                        &wlr_keyboard.modifiers,
                    );
                }
            }
        }
    }

    fn handleDestroy(listener: *wl.Listener(*wlr.LayerSurfaceV1), _: *wlr.LayerSurfaceV1) void {
        const self: *LayerSurface = @fieldParentPtr("destroy", listener);

        self.link.remove();
        self.server.arrangeLayers(self.layer_surface.output.?);
        self.commit.link.remove();
        self.destroy.link.remove();
        gpa.destroy(self);
    }
};
