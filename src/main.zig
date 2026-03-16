const args = @import("args");
const mzterwm = @import("mzterwm");
const proto = @import("mzterwm-proto");
const std = @import("std");
const wl = @import("wayland").client.wl;

/// Options struct for zig-args
const Options = struct {
    pub const shorthands = .{
        .c = "config",
    };

    pub const meta = .{
        .full_text = "The mzterwm window manager for River",
        .option_docs = .{
            .help = "Show this help text and exit",
            .config = "A configuration file to use instead of the default",
        },
    };

    help: bool = false,
    config: ?[]const u8 = null,
};

pub fn main() !u8 {
    var gpa = if (@import("builtin").mode == .Debug) std.heap.DebugAllocator(.{}).init else {};
    const alloc = if (@TypeOf(gpa) == void) std.heap.c_allocator else gpa.allocator();
    defer if (@TypeOf(gpa) != void) {
        _ = gpa.deinit();
    };

    var stdio_buf: [512]u8 = undefined;
    const parse_res = args.parseForCurrentProcess(Options, alloc, .print) catch |e| switch (e) {
        error.InvalidArguments => {
            // print help to stderr
            var writer = std.fs.File.stderr().writer(&stdio_buf);
            try args.printHelp(Options, "mzterwm", &writer.interface);
            try writer.interface.flush();
            return 1;
        },
        else => return e,
    };
    defer parse_res.deinit();

    if (parse_res.options.help) {
        var writer = std.fs.File.stdout().writer(&stdio_buf);
        try args.printHelp(Options, "mzterwm", &writer.interface);
        try writer.interface.flush();
        return 0;
    }

    if (parse_res.positionals.len != 0) {
        std.log.err("Expected no positional arguments, got {}", .{parse_res.positionals.len});
        return 1;
    }

    var config_arena: std.heap.ArenaAllocator = .init(alloc);
    defer config_arena.deinit();

    const config = mzterwm.Config.load(
        alloc,
        config_arena.allocator(),
        parse_res.options.config,
    ) catch |e| {
        std.log.err("Could not load configuration file: {}", .{e});
        return 1;
    };
    config.validate() catch {
        std.log.err("Configuration file is invalid.", .{});
        return 1;
    };

    var dpy: *wl.Display = try .connect(null);
    defer dpy.disconnect();

    const sockpath = try proto.findSocketPath(alloc);
    defer {
        std.fs.cwd().deleteFile(sockpath) catch |e| {
            std.log.warn("Couldn't delete socket after shutdown: {}", .{e});
        };
        alloc.free(sockpath);
    }

    var ipc: mzterwm.IPCHandler = try .initOn(sockpath);
    defer ipc.deinit(alloc);

    const reg = try dpy.getRegistry();
    defer reg.destroy();

    var globals: *mzterwm.Globals = try .setupListenerAndCollect(alloc, reg, dpy);
    defer globals.deinit();

    var wm: mzterwm.WindowManager = .init(globals, &ipc, config);
    defer wm.deinit();
    try wm.setup();

    try mzterwm.mainLoop(dpy, &wm, &ipc);
    return 0;
}
