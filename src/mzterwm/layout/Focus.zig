//! The focus layout is similar to the old rivertile from river-classic.
//! There is one column with the "primary" window, all other windows being moved to the other column
//! where they are stacked orthogonally.

const std = @import("std");
const mzterwm = @import("../../root.zig");

const river = @import("wayland").client.river;

const Focus = @This();

primary_ratio: mzterwm.Ratio,
direction: mzterwm.Cardinal,

pub const init: Focus = .{
    .primary_ratio = .half,
    .direction = .left,
};

pub const Global = struct {
    keybinds: []KeyData,

    pub fn init(wm: *mzterwm.WindowManager) !Global {
        const keybinds = try wm.globals.alloc.alloc(KeyData, wm.config.layouts.focus.keybinds.len);
        errdefer wm.globals.alloc.free(keybinds);

        for (keybinds, wm.config.layouts.focus.keybinds) |*keydat, conf| {
            keydat.* = .{
                .wm = wm,
                .bind = try wm.keys.register(KeyData, .{
                    .keysym = conf.key.xkb,
                    .mods = conf.mods.toRiver(),
                }, onUserKey, keydat),
                .action = conf.action,
            };
        }

        return .{ .keybinds = keybinds };
    }

    pub fn deinit(self: *Global, wm: *mzterwm.WindowManager) void {
        wm.globals.alloc.free(self.keybinds);
    }

    pub fn enter(self: *Global) void {
        for (self.keybinds) |bind| {
            bind.bind.enable();
        }
    }

    pub fn leave(self: *Global) void {
        for (self.keybinds) |bind| {
            bind.bind.disable();
        }
    }
};

pub const KeyData = struct {
    wm: *mzterwm.WindowManager,
    bind: *mzterwm.KeyManager.KeyBind,
    action: Action,
};

// These are PascalCase so the Ziggy config looks nice
pub const Action = union(enum) {
    ResizePrimary: struct { by: i9 },

    /// Like ResizePrimary, but inverted iff the primary direction is down or right
    ResizePrimaryDirectional: struct { by: i9 },

    SetDirection: struct { to: mzterwm.Cardinal },
};

pub const Config = struct {
    keybinds: []const struct {
        key: mzterwm.Config.Keysym,
        mods: mzterwm.Config.Modifiers,
        action: Action,
    } = &.{},
};

fn onUserKey(_: *river.XkbBindingV1, ev: river.XkbBindingV1.Event, keydat: *KeyData) void {
    if (ev != .pressed) return;

    const cur_outp = keydat.wm.selectedOutput() orelse return;
    const ts = &(cur_outp.tag_space orelse return);
    std.debug.assert(ts.tagdata[ts.primary].layout == .focus);
    const self = &ts.tagdata[ts.primary].layout.focus;

    switch (keydat.action) {
        .ResizePrimary => |opt| {
            var new_size = self.primary_ratio.val + opt.by;
            new_size = std.math.clamp(new_size, 16, 255 - 16);
            self.primary_ratio.val = @intCast(new_size);
        },
        .ResizePrimaryDirectional => |opt| {
            var by = opt.by;
            switch (self.direction) {
                .down, .right => by *= -1,
                .up, .left => {},
            }
            var new_size = self.primary_ratio.val + by;
            new_size = std.math.clamp(new_size, 16, 255 - 16);
            self.primary_ratio.val = @intCast(new_size);
        },
        .SetDirection => |opt| {
            self.direction = opt.to;
        }
    }
}

pub fn performLayout(
    self: *Focus,
    wm: *mzterwm.WindowManager,
    region: mzterwm.Region,
    windows: []const *mzterwm.WindowManager.Window,
) !void {
    const gap = wm.config.gaps.window;
    const axis = self.direction.axis();

    if (windows.len == 0) return;
    if (windows.len == 1) {
        windows[0].render.updateRegion(region.inset(gap));
        return;
    }

    const primary, const secondary = region.sliceCardinal(self.primary_ratio, self.direction.opposite());

    windows[0].render.updateRegion(primary.inset(gap));

    const secondary_off = switch (axis) {
        .row => secondary.size[1] / @as(u31, @truncate(windows.len - 1)),
        .col => secondary.size[0] / @as(u31, @truncate(windows.len - 1)),
    };
    const secondary_size: [2]u31 = switch (axis) {
        .row => .{ secondary.size[0], secondary_off },
        .col => .{ secondary_off, secondary.size[1] },
    };

    for (windows[1..], 0..) |win, i_usize| {
        const i: u31 = @truncate(i_usize);
        const secondary_region: mzterwm.Region = switch (axis) {
            .row => .{
                .pos = .{ secondary.pos[0], secondary.pos[1] + secondary_off * i },
                .size = secondary_size,
            },
            .col => .{
                .pos = .{ secondary.pos[0] + secondary_off * i, secondary.pos[1] },
                .size = secondary_size,
            },
        };

        win.render.updateRegion(secondary_region.inset(gap));
    }
}
