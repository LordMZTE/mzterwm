const std = @import("std");

/// The current protocol version.  When a client connects, this must match.
pub const version: u32 = 0;

/// Gets the path where the IPC socket of mzterwm is considering the current environment.
/// Return value is allocated with the given allocator.
pub fn findSocketPath(alloc: std.mem.Allocator) ![]u8 {
    const rtd = std.posix.getenv("XDG_RUNTIME_DIR") orelse {
        std.log.err("Couldn't get socket path because XDG_RUNTIME_DIR isn't set.", .{});
        return error.MissingEnv;
    };
    const wl_dpy = std.posix.getenv("WAYLAND_DISPLAY") orelse {
        std.log.err("Couldn't get socket path because WAYLAND_DISPLAY isn't set.", .{});
        return error.MissingEnv;
    };

    return std.fmt.allocPrint(alloc, "{s}/mzterwm-{s}.sock", .{ rtd, wl_dpy });
}
