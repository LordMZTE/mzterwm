const std = @import("std");
const wayland = @import("wayland");

const wl = wayland.client.wl;

pub const Config = @import("mzterwm/Config.zig");
pub const Globals = @import("mzterwm/Globals.zig");
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
pub fn mainLoop(dpy: *wl.Display, wm: *WindowManager) !void {
    while (true) {
        if (dpy.dispatch() != .SUCCESS) return error.WaylandIPCFail;

        switch (wm.run_state) {
            .keep_running => {},
            .errored => return error.WindowManagerFailure,
            .graceful_shutdown => break,
        }
    }
}

pub const Cardinal = enum {
    row,
    col,

    pub fn orthogonal(self: Cardinal) Cardinal {
        return switch (self) {
            .row => .col,
            .col => .row,
        };
    }
};

pub const Region = struct {
    pos: @Vector(2, i32),
    size: @Vector(2, u31),

    pub const zero: Region = .{ .pos = @splat(0), .size = @splat(0) };

    /// Slice the region in half such that the first half will have a size according to `ratio` and
    /// both halves will be stacked along `direction`.
    pub fn slice(self: Region, ratio: Ratio, direction: Cardinal) [2]Region {
        const first: Region = switch (direction) {
            .row => .{
                .pos = self.pos,
                .size = .{ ratio.scale(self.size[0]), self.size[1] },
            },
            .col => .{
                .pos = self.pos,
                .size = .{ self.size[0], ratio.scale(self.size[1]) },
            },
        };

        const second: Region = switch (direction) {
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

    pub fn contains(self: Region, point: @Vector(2, i32)) bool {
        const corner = self.pos + self.size;

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

test {
    _ = Ratio;
}
