const Server = @import("../server.zig").Server;
const std = @import("std");
const posix = std.posix;

const wl = @import("wayland").server.wl;

const wlr = @import("wlroots");
const xkb = @import("xkbcommon");

const lua = @import("../server.zig").lua;
const lua_api = @import("../lua/methods.zig");

const gpa = std.heap.c_allocator;

pub const Toplevel = struct {
    server: *Server,
    link: wl.list.Link = undefined,
    xdg_toplevel: *wlr.XdgToplevel,
    scene_tree: *wlr.SceneTree,

    surface_scene_tree: *wlr.SceneTree,
    border_node: *wlr.SceneRect,

    x: i32 = 0,
    y: i32 = 0,

    // workspace tag
    tags: u32 = 1,

    commit: wl.Listener(*wlr.Surface) = .init(handleCommit),
    map: wl.Listener(void) = .init(handleMap),
    unmap: wl.Listener(void) = .init(handleUnmap),
    destroy: wl.Listener(void) = .init(handleDestroy),
    request_move: wl.Listener(*wlr.XdgToplevel.event.Move) = .init(handleRequestMove),
    request_resize: wl.Listener(*wlr.XdgToplevel.event.Resize) = .init(handleRequestResize),

    // To be able to have specific workspaces, Like firefox always on workspace 4.
    // the title can and will change, the app_id is const
    set_title: wl.Listener(void) = .init(handleSetTitle),
    set_app_id: wl.Listener(void) = .init(handleSetAppId),

    fn handleCommit(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
        const toplevel: *Toplevel = @fieldParentPtr("commit", listener);

        if (toplevel.xdg_toplevel.base.initial_commit) {
            _ = toplevel.xdg_toplevel.setSize(800, 600);

            toplevel.server.reTile();
        }
        // inital commit must be acknowleged
        //_ = toplevel.xdg_toplevel.setSize(0, 0);
        // lehetne itt is a reTile(), de race condition.
        // egy egy cliens hamarabb kapja meg a setSize(0,0) eredményt,
        // minthogy a reTile() megtudná változtatni a méretet, így a cliens a default méretét fogja használni a 0,0 helyett

        const surface_state = toplevel.xdg_toplevel.base.geometry;
        const border_width = toplevel.server.border_width;

        toplevel.border_node.setSize(surface_state.width + border_width * 2, surface_state.height + border_width * 2);
        toplevel.border_node.node.setPosition(0, 0);
        toplevel.surface_scene_tree.node.setPosition(border_width, border_width);
    }

    fn handleMap(listener: *wl.Listener(void)) void {
        const toplevel: *Toplevel = @fieldParentPtr("map", listener);
        //toplevel.x = 50;
        //toplevel.y = 50;
        //toplevel.scene_tree.node.setPosition(toplevel.x, toplevel.y);
        toplevel.server.toplevels.prepend(toplevel);
        toplevel.server.focusView(toplevel, toplevel.xdg_toplevel.base.surface);

        // --- CALL LUA: wm.on_manage(client) ---
        const L = toplevel.server.lua_state;

        _ = lua.lua_getglobal(L, "wm"); // Push 'wm' table
        _ = lua.lua_getfield(L, -1, "on_manage"); // Push 'wm.on_manage' function

        if (lua.lua_isfunction(L, -1)) {
            // It's a valid function! Push the lockbox to the stack.
            lua_api.push_client(L, toplevel);

            // Execute it with 1 argument, 0 return values
            if (lua.lua_pcallk(L, 1, 0, 0, 0, null) != lua.LUA_OK) {
                const err_msg = lua.lua_tolstring(L, -1, null);
                std.log.err("Lua on_manage Error: {s}", .{std.mem.span(err_msg)});
                lua.lua_pop(L, 1); // Pop error
            }
        } else {
            lua.lua_pop(L, 1); // Pop the nil if the function wasn't found
        }
        lua.lua_pop(L, 1); // Pop the 'wm' table
        // --------------------------------------

        toplevel.server.reTile();
    }

    fn handleUnmap(listener: *wl.Listener(void)) void {
        const toplevel: *Toplevel = @fieldParentPtr("unmap", listener);
        toplevel.link.remove();

        toplevel.server.reTile();
    }

    fn handleDestroy(listener: *wl.Listener(void)) void {
        const toplevel: *Toplevel = @fieldParentPtr("destroy", listener);
        const server = toplevel.server;
        toplevel.commit.link.remove();
        toplevel.map.link.remove();
        toplevel.unmap.link.remove();
        toplevel.destroy.link.remove();
        //toplevel.request_move.link.remove();
        //toplevel.request_resize.link.remove();
        toplevel.scene_tree.node.destroy();
        //toplevel.link.remove();

        toplevel.set_app_id.link.remove();
        toplevel.set_title.link.remove();

        // Only remove the link if it is actually attached to a list!
        if (toplevel.link.prev != null) {
            toplevel.link.remove();
        }

        // Do the same for your other listeners just to be safe
        if (toplevel.request_move.link.prev != null) {
            toplevel.request_move.link.remove();
        }
        if (toplevel.request_resize.link.prev != null) {
            toplevel.request_resize.link.remove();
        }

        gpa.destroy(toplevel);
        server.reTile();
    }

    fn handleRequestMove(
        listener: *wl.Listener(*wlr.XdgToplevel.event.Move),
        _: *wlr.XdgToplevel.event.Move,
    ) void {
        // const toplevel: *Toplevel = @fieldParentPtr("request_move", listener);
        //const server = toplevel.server;
        //server.grabbed_view = toplevel;
        //server.cursor_mode = .move;
        //server.grab_x = server.cursor.x - @as(f64, @floatFromInt(toplevel.x));
        //server.grab_y = server.cursor.y - @as(f64, @floatFromInt(toplevel.y));
        _ = listener;
    }

    fn handleRequestResize(
        listener: *wl.Listener(*wlr.XdgToplevel.event.Resize),
        event: *wlr.XdgToplevel.event.Resize,
    ) void {
        //const toplevel: *Toplevel = @fieldParentPtr("request_resize", listener);
        //const server = toplevel.server;

        //server.grabbed_view = toplevel;
        //server.cursor_mode = .resize;
        //server.resize_edges = event.edges;

        //const box = toplevel.xdg_toplevel.base.geometry;

        //const border_x = toplevel.x + box.x + if (event.edges.right) box.width else 0;
        //const border_y = toplevel.y + box.y + if (event.edges.bottom) box.height else 0;
        //server.grab_x = server.cursor.x - @as(f64, @floatFromInt(border_x));
        //server.grab_y = server.cursor.y - @as(f64, @floatFromInt(border_y));

        //server.grab_box = box;
        //server.grab_box.x += toplevel.x;
        //server.grab_box.y += toplevel.y;
        _ = event;
        _ = listener;
    }
    fn handleSetTitle(listener: *wl.Listener(void)) void {
        const toplevel: *Toplevel = @fieldParentPtr("set_title", listener);
        const title = toplevel.xdg_toplevel.title orelse "unknown";
        _ = title; // autofix
        //std.log.info("Window title set to: {s}\n", .{title});
    }

    fn handleSetAppId(listener: *wl.Listener(void)) void {
        const toplevel: *Toplevel = @fieldParentPtr("set_app_id", listener);
        const app_id = toplevel.xdg_toplevel.app_id orelse "unknown";
        _ = app_id; // autofix
        //std.log.info("Window app_id set to: {s}\n", .{app_id});
    }
};
