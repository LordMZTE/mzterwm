const std = @import("std");

const IPCHandler = @This();

srv: std.net.Server,

pub fn initOn(sockpath: []const u8) !IPCHandler {
    const addr = try std.net.Address.initUnix(sockpath);
    return .{ .srv = try addr.listen(.{}) };
}

pub fn deinit(self: *IPCHandler) void {
    self.srv.deinit();
}

/// Called from the event loop when any file descriptor that isn't otherwise used and is part of the
/// event loop becomes readable.
pub fn onFdReadable(self: *IPCHandler, epfd: std.posix.fd_t, fd: std.posix.fd_t) !void {
    _ = self; // autofix
    _ = epfd; // autofix
    _ = fd; // autofix
}
