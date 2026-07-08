const std = @import("std");
const wayland = @import("wayland");

const wl = wayland.client.wl;

pub const action = @import("mzterwm/action.zig");
pub const posix = @import("mzterwm/posix.zig");

pub const Config = @import("mzterwm/Config.zig");
pub const Globals = @import("mzterwm/Globals.zig");
pub const IPCHandler = @import("mzterwm/IPCHandler.zig");
pub const KeyManager = @import("mzterwm/KeyManager.zig");
pub const Layout = @import("mzterwm/layout.zig").Layout;
pub const TagSpace = @import("mzterwm/TagSpace.zig");
pub const WindowManager = @import("mzterwm/WindowManager.zig");

/// Wrapper around a display roundtrip with error handling
pub fn roundtrip(dpy: *wl.Display) !void {
    return switch (dpy.roundtrip()) {
        .SUCCESS => {},
        else => error.WaylandIPCFail,
    };
}

/// Run the main loop.  This dispatches wayland events and socket requests.
pub fn mainLoop(dpy: *wl.Display, wm: *WindowManager, ipc: *IPCHandler) !void {
    const epfd: posix.EPoll = try .init();
    defer epfd.deinit();

    const sigset = sigs: {
        var sigs = std.posix.sigemptyset();
        std.posix.sigaddset(&sigs, std.os.linux.SIG.INT);
        std.posix.sigaddset(&sigs, std.os.linux.SIG.TERM);
        // Maybe for future config hot reloading
        //std.posix.sigaddset(&sigs, std.os.linux.SIG.USR1);
        break :sigs sigs;
    };
    std.posix.sigprocmask(std.posix.SIG.BLOCK, &sigset, null);

    const sigfd = try std.posix.signalfd(-1, &sigset, 0);
    defer _ = std.posix.system.close(sigfd);

    const EPOLL = std.os.linux.EPOLL;

    const wlfd = dpy.getFd();
    try epfd.addFd(wlfd, EPOLL.IN | EPOLL.HUP | EPOLL.ERR);
    try epfd.addFd(sigfd, EPOLL.IN | EPOLL.HUP | EPOLL.ERR);
    try epfd.addFd(ipc.srv.socket.handle, EPOLL.IN | EPOLL.HUP | EPOLL.ERR);

    if (dpy.flush() != .SUCCESS) return error.WaylandIPCFail;

    var evbuf: [64]std.posix.system.epoll_event = undefined;
    while (true) {
        const evs = try epfd.wait(&evbuf, -1);

        for (evs) |ev| {
            if (ev.data.fd == wlfd) {
                if (ev.events & (EPOLL.ERR | EPOLL.HUP) != 0) {
                    std.log.err("Wayland compositor closed socket", .{});
                    return error.WaylandIPCFail;
                }
                if (dpy.dispatch() != .SUCCESS) return error.WaylandIPCFail;
                if (dpy.flush() != .SUCCESS) return error.WaylandIPCFail;
            } else if (ev.data.fd == sigfd) {
                var siginf: std.os.linux.signalfd_siginfo = undefined;
                std.debug.assert(try std.posix.read(sigfd, std.mem.asBytes(&siginf)) ==
                    @sizeOf(std.os.linux.signalfd_siginfo));
                std.log.info("Got signal {}, exiting", .{siginf.signo});
                return;
            } else if (ipc.onFdReadable(
                epfd,
                ev.data.fd,
                ev.events,
            ) catch |e| {
                std.log.err("In IPC handler: {}", .{e});
                return e;
            }) {
                // There's a good chance we got an IPC call that caused some wayland events, so
                // flush any queues.
                if (dpy.flush() != .SUCCESS) return error.WaylandIPCFail;
            } else {
                std.log.err("Got epoll event on unknown fd {}.  This is a bug.", .{ev.data.fd});
            }
        }

        switch (wm.run_state) {
            .keep_running => {},
            .errored => return error.WindowManagerFailure,
            .graceful_shutdown => break,
        }
    }
}

pub const Axis = enum {
    row,
    col,

    pub fn orthogonal(self: Axis) Axis {
        return switch (self) {
            .row => .col,
            .col => .row,
        };
    }
};

pub const Cardinal = enum {
    up,
    down,
    left,
    right,

    pub fn axis(self: Cardinal) Axis {
        return switch (self) {
            .up, .down => .col,
            .left, .right => .row,
        };
    }

    pub fn opposite(self: Cardinal) Cardinal {
        return switch (self) {
            .up => .down,
            .down => .up,
            .left => .right,
            .right => .left,
        };
    }
};

pub const Region = struct {
    pos: @Vector(2, i32),
    size: @Vector(2, u31),

    pub const zero: Region = .{ .pos = @splat(0), .size = @splat(0) };

    /// Slice the region in half such that the first half will have a size according to `ratio` and
    /// both halves will be stacked along `direction`.
    pub fn sliceAxis(self: Region, ratio: Ratio, axis: Axis) [2]Region {
        const first: Region = switch (axis) {
            .row => .{
                .pos = self.pos,
                .size = .{ ratio.scale(self.size[0]), self.size[1] },
            },
            .col => .{
                .pos = self.pos,
                .size = .{ self.size[0], ratio.scale(self.size[1]) },
            },
        };

        const second: Region = switch (axis) {
            .row => .{
                .pos = .{ self.pos[0] + first.size[0], self.pos[1] },
                .size = .{ self.size[0] - first.size[0], self.size[1] },
            },
            .col => .{
                .pos = .{ self.pos[0], self.pos[1] + first.size[1] },
                .size = .{ self.size[0], self.size[1] - first.size[1] },
            },
        };

        return .{ first, second };
    }

    pub fn sliceCardinal(self: Region, ratio: Ratio, cardinal: Cardinal) [2]Region {
        var axis = self.sliceAxis(ratio, cardinal.axis());

        const cusp = switch (cardinal) {
            .down, .right => return axis,
            .left => axis[0].pos + @as(@Vector(2, u31), .{ axis[1].size[0], 0 }),
            .up => axis[0].pos + @as(@Vector(2, u31), .{ 0, axis[1].size[1] }),
        };

        axis[1].pos = axis[0].pos;
        axis[0].pos = cusp;
        return axis;
    }

    pub fn contains(self: Region, point: @Vector(2, i32)) bool {
        const corner = self.bottomRight();

        return @reduce(.And, point >= self.pos) and
            @reduce(.And, point <= corner);
    }

    pub fn inset(self: Region, size: u31) Region {
        const size_vec: @Vector(2, u31) = @splat(size);
        return .{
            .pos = self.pos +| size_vec,
            .size = self.size -| size_vec * @as(@Vector(2, u31), @splat(2)),
        };
    }

    pub fn outset(self: Region, size: u31) Region {
        const size_vec: @Vector(2, u31) = @splat(size);
        return .{
            .pos = self.pos -| size_vec,
            .size = self.size +| size_vec * @as(@Vector(2, u31), @splat(2)),
        };
    }

    pub fn center(self: Region) @Vector(2, i32) {
        return self.pos + (self.size / @as(@Vector(2, u31), @splat(2)));
    }

    /// Returns the position of the lower right corner of the region.
    pub fn bottomRight(self: Region) @Vector(2, i32) {
        return self.pos + self.size;
    }

    /// Given a point that may be outside the region, returns the closest point inside the region.
    pub fn clampPoint(self: Region, point: @Vector(2, i32)) @Vector(2, i32) {
        return std.math.clamp(point, self.pos, self.bottomRight());
    }

    test "center" {
        const region: Region = .{ .pos = .{ 10, 10 }, .size = .{ 10, 10 } };
        try std.testing.expectEqual(@as(@Vector(2, i32), @splat(15)), region.center());
    }

    test "clampPoint" {
        const region: Region = .{ .pos = .{ 10, 10 }, .size = .{ 10, 10 } };

        // Inside region - should return the point unchanged
        try std.testing.expectEqual(@as(@Vector(2, i32), .{ 10, 10 }), region.clampPoint(.{ 10, 10 }));

        // Corner cases - should clamp both axes
        try std.testing.expectEqual(@as(@Vector(2, i32), .{ 10, 10 }), region.clampPoint(.{ 5, 5 }));
        try std.testing.expectEqual(@as(@Vector(2, i32), .{ 20, 10 }), region.clampPoint(.{ 25, 5 }));
        try std.testing.expectEqual(@as(@Vector(2, i32), .{ 10, 20 }), region.clampPoint(.{ 5, 25 }));
        try std.testing.expectEqual(@as(@Vector(2, i32), .{ 20, 20 }), region.clampPoint(.{ 25, 25 }));
    }

    test "sliceAxis" {
        const region: Region = .{ .pos = .{ 10, 10 }, .size = .{ 20, 30 } };

        try std.testing.expectEqual([2]Region{
            .{ .pos = .{ 10, 10 }, .size = .{ 10, 30 } },
            .{ .pos = .{ 20, 10 }, .size = .{ 10, 30 } },
        }, region.sliceAxis(.half, .row));

        try std.testing.expectEqual([2]Region{
            .{ .pos = .{ 10, 10 }, .size = .{ 20, 15 } },
            .{ .pos = .{ 10, 25 }, .size = .{ 20, 15 } },
        }, region.sliceAxis(.half, .col));
    }

    test "sliceCardinal" {
        const region: Region = .{ .pos = .{ 10, 10 }, .size = .{ 20, 30 } };

        // vertical
        try std.testing.expectEqual([2]Region{
            .{ .pos = .{ 10, 10 }, .size = .{ 20, 15 } },
            .{ .pos = .{ 10, 25 }, .size = .{ 20, 15 } },
        }, region.sliceCardinal(.half, .down));
        try std.testing.expectEqual([2]Region{
            .{ .pos = .{ 10, 25 }, .size = .{ 20, 15 } },
            .{ .pos = .{ 10, 10 }, .size = .{ 20, 15 } },
        }, region.sliceCardinal(.half, .up));

        // horizontal
        try std.testing.expectEqual([2]Region{
            .{ .pos = .{ 10, 10 }, .size = .{ 10, 30 } },
            .{ .pos = .{ 20, 10 }, .size = .{ 10, 30 } },
        }, region.sliceCardinal(.half, .right));
        try std.testing.expectEqual([2]Region{
            .{ .pos = .{ 20, 10 }, .size = .{ 10, 30 } },
            .{ .pos = .{ 10, 10 }, .size = .{ 10, 30 } },
        }, region.sliceCardinal(.half, .left));
    }

    test "contains" {
        const region: Region = .{ .pos = .{ 10, 10 }, .size = .{ 20, 30 } };
        const corner = region.bottomRight();

        try std.testing.expect(region.contains(region.pos));
        try std.testing.expect(region.contains(corner));

        // points just outside the region are excluded
        try std.testing.expect(!region.contains(region.pos - @as(@Vector(2, i32), .{ 1, 1 })));
        try std.testing.expect(!region.contains(corner + @as(@Vector(2, i32), .{ 1, 1 })));
    }

    test "inset" {
        const region: Region = .{ .pos = .{ 10, 10 }, .size = .{ 20, 30 } };

        try std.testing.expectEqual(@as(Region, .{ .pos = .{ 12, 12 }, .size = .{ 16, 26 } }), region.inset(2));
        try std.testing.expectEqual(@as(Region, .{ .pos = .{ 14, 14 }, .size = .{ 12, 22 } }), region.inset(4));
    }

    test "outset" {
        const region: Region = .{ .pos = .{ 10, 10 }, .size = .{ 20, 30 } };

        try std.testing.expectEqual(@as(Region, .{ .pos = .{ 8, 8 }, .size = .{ 24, 34 } }), region.outset(2));
        try std.testing.expectEqual(@as(Region, .{ .pos = .{ 6, 6 }, .size = .{ 28, 38 } }), region.outset(4));
    }
};

/// An 8-bit fixed-point ratio.
pub const Ratio = struct {
    val: u8,

    pub const zero: Ratio = .{ .val = 0 };
    pub const one: Ratio = .{ .val = 255 };
    pub const half: Ratio = .{ .val = 128 }; // half enough

    pub fn inverse(self: Ratio) Ratio {
        return .{ .val = 255 - self.val };
    }

    /// Scale a scalar value by this ratio.  Do not use when close to the given integer limit, as
    /// this will multiply by a number potentially as large as 255 first.
    pub fn scale(self: Ratio, x: anytype) @TypeOf(x) {
        if (@typeInfo(@TypeOf(x)) == .vector) {
            return @divTrunc(x * @as(@TypeOf(x), @splat(self.val)), @as(@TypeOf(x), @splat(255)));
        }

        return @divTrunc(x * @as(@TypeOf(x), self.val), 255);
    }

    test "zero collapses anything to zero" {
        try std.testing.expectEqual(0, Ratio.zero.scale(420));
        try std.testing.expectEqual(0, Ratio.zero.scale(69));
        try std.testing.expectEqual(0, Ratio.zero.scale(69420));
    }

    test "one preserves value" {
        try std.testing.expectEqual(420, Ratio.one.scale(420));
        try std.testing.expectEqual(69, Ratio.one.scale(69));
        try std.testing.expectEqual(69420, Ratio.one.scale(69420));
    }
};

/// Converts a normal rgba color to the weird 32 bit color format with pre-multiplied alpha River
/// wants.
pub fn colorToRiver(color: @Vector(4, u8)) @Vector(4, u32) {
    const factor = 0xffff_ffff / 0xff;
    const alpha_ratio: Ratio = .{ .val = color[3] };
    const prepremul: @Vector(4, u40) = @as(@Vector(4, u40), color) * @as(@Vector(4, u40), @splat(factor));
    return @truncate(alpha_ratio.scale(prepremul));
}

pub const RotFn = @TypeOf(rotFocusFwd);

/// Rotate some focus index forward
pub fn rotFocusFwd(comptime T: type, focus: *T, max: T) void {
    focus.* = if (focus.* >= max) 0 else focus.* + 1;
}

/// Like rotFocusFwd, but return true if wrapping happened
pub fn rotFocusFwdCheckWrap(comptime T: type, focus: *T, max: T) bool {
    const prev = focus.*;
    rotFocusFwd(T, focus, max);
    return focus.* < prev;
}

/// Rotate some focus index backward
pub fn rotFocusBck(comptime T: type, focus: *T, max: T) void {
    focus.* = if (focus.* == 0 or focus.* > max) max else focus.* - 1;
}

/// Like rotFocusBck, but return true if wrapping happened
pub fn rotFocusBckCheckWrap(comptime T: type, focus: *T, max: T) bool {
    const prev = focus.*;
    rotFocusBck(T, focus, max);
    return focus.* > prev;
}

test {
    _ = Ratio;
    _ = Region;
}

test "focus rotation in bounds" {
    var n: u8 = 1;
    rotFocusBck(u8, &n, 5);
    try std.testing.expectEqual(0, n);
    rotFocusBck(u8, &n, 5);
    try std.testing.expectEqual(5, n);
    rotFocusBck(u8, &n, 5);
    try std.testing.expectEqual(4, n);

    rotFocusFwd(u8, &n, 5);
    try std.testing.expectEqual(5, n);
    rotFocusFwd(u8, &n, 5);
    try std.testing.expectEqual(0, n);
    rotFocusFwd(u8, &n, 5);
    try std.testing.expectEqual(1, n);
}

test "focus rotation out of bounds" {
    var n: u8 = 42;
    rotFocusBck(u8, &n, 5);
    try std.testing.expectEqual(5, n);

    n = 42;
    rotFocusFwd(u8, &n, 5);
    try std.testing.expectEqual(0, n);
}

test "focus rotation zero" {
    var n: u8 = 42;
    rotFocusBck(u8, &n, 0);
    try std.testing.expectEqual(0, n);

    n = 42;
    rotFocusFwd(u8, &n, 0);
    try std.testing.expectEqual(0, n);
}
