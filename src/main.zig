const std = @import("std");
const wl = @import("wayland").client.wl;
const mzterwm = @import("mzterwm");

pub fn main() !u8 {
    var gpa = if (@import("builtin").mode == .Debug) std.heap.DebugAllocator(.{}).init else {};
    const alloc = if (@TypeOf(gpa) == void) std.heap.c_allocator else gpa.allocator();
    defer if (@TypeOf(gpa) != void) {
        _ = gpa.deinit();
    };

    var config_arena: std.heap.ArenaAllocator = .init(alloc);
    defer config_arena.deinit();

    const config = mzterwm.Config.load(alloc, config_arena.allocator()) catch |e| {
        std.log.err("Could not load configuration file: {}", .{e});
        return 1;
    };
    config.validate() catch {
        std.log.err("Configuration file is invalid.", .{});
        return 1;
    };

    var dpy: *wl.Display = try .connect(null);
    defer dpy.disconnect();

    const reg = try dpy.getRegistry();
    defer reg.destroy();

    var globals: *mzterwm.Globals = try .setupListenerAndCollect(alloc, reg, dpy);
    defer globals.deinit();

    var wm: mzterwm.WindowManager = .init(globals, config);
    defer wm.deinit();
    try wm.setup();

    try mzterwm.mainLoop(dpy, &wm);
    return 0;
}
