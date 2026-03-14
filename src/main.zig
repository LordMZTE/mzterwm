const std = @import("std");
const wl = @import("wayland").client.wl;
const mzterwm = @import("mzterwm");

pub fn main() !void {
    var gpa = if (@import("builtin").mode == .Debug) std.heap.DebugAllocator(.{}).init else {};
    const alloc = if (@TypeOf(gpa) == void) std.heap.c_allocator else gpa.allocator();
    defer if (@TypeOf(gpa) != void) {
        _ = gpa.deinit();
    };

    var dpy: *wl.Display = try .connect(null);
    defer dpy.disconnect();

    const reg = try dpy.getRegistry();
    defer reg.destroy();

    var globals: *mzterwm.Globals = try .setupListenerAndCollect(alloc, reg, dpy);
    defer globals.deinit();

    var wm: mzterwm.WindowManager = .init(globals);
    defer wm.deinit();
    wm.setup();

    try mzterwm.mainLoop(dpy, &wm);
}
