const std = @import("std");
const s2s = @import("s2s");

pub const pkt = @import("proto/pkt.zig");
pub const Client = @import("proto/Client.zig");

/// The current protocol version.  When a client connects, this must match.
pub const ProtocolVersion = u32;
pub const version: ProtocolVersion = 2;

pub const tag_bitwidth = 32;
pub const TagMask = std.meta.Int(.unsigned, tag_bitwidth);
pub const TagIdx = std.math.Log2Int(TagMask);

pub const readPkt = s2s.deserializeAlloc;

pub fn writePkt(stream: *std.Io.Writer, packet: anytype) !void {
    return s2s.serialize(stream, @TypeOf(packet), packet);
}

pub const freePkt = s2s.free;

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
