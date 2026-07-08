const std = @import("std");
const mzterwm = @import("../../root.zig");

const river = @import("wayland").client.river;

const TagSpace = @import("../TagSpace.zig");

const Size = @Vector(2, u31);
const Pos = @Vector(2, i32);

const Scroll = @This();

const log = std.log.scoped(.layout_scroll);

// These limits really just exist to prevent the user from breaking our code :P
const min_col_size = 32;
const max_col_size = std.math.maxInt(u31) / 2;

direction: mzterwm.Cardinal,
columns: std.ArrayList(Column),
scroll: u31,

pub const Column = struct {
    /// Size (width or height) of the column in logical units.
    size: u31,

    /// Number of windows in this column.  Must be nonzero
    nwins: u8,
};

pub const Global = struct {
    keybinds: []KeyData,

    pub fn init(wm: *mzterwm.WindowManager) !Global {
        const alloc = wm.globals.alloc;
        const keybinds = try alloc.alloc(KeyData, wm.config.layouts.scroll.keybinds.len);
        errdefer alloc.free(keybinds);

        for (keybinds, wm.config.layouts.scroll.keybinds) |*keydat, conf| {
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

    pub fn enter(self: *Global, wm: *mzterwm.WindowManager) void {
        for (self.keybinds) |k| {
            k.bind.enable(&wm.keys);
        }
    }

    pub fn leave(self: *Global, wm: *mzterwm.WindowManager) void {
        for (self.keybinds) |k| {
            k.bind.disable(&wm.keys);
        }
    }
};

pub const KeyData = struct {
    wm: *mzterwm.WindowManager,
    bind: *mzterwm.KeyManager.KeyBind,
    action: Action,
};

pub const Action = union(enum) {
    /// Sets the direction to layout in
    set_direction: mzterwm.Cardinal,

    /// Resizes the current column by the given amount
    resize_col: i32,

    /// Adjusts the number of windows in the current column by the given count
    adjust_nwins: i9,

    /// Scrolls in the layout direction by the given amount
    scroll: i32,

    /// Scrolls in the layout direction by the given amount for right and down directions and
    /// against it in up and left directions.
    scroll_directional: i32,
};

pub const Config = struct {
    keybinds: []const struct {
        key: mzterwm.Config.Keysym,
        mods: mzterwm.Config.Modifiers,
        action: Action,
    } = &.{},
};

pub fn init(wm: *mzterwm.WindowManager) !Scroll {
    _ = wm;
    return .{
        .direction = .right,
        .columns = .empty,
        .scroll = 0,
    };
}

pub fn deinit(self: *Scroll, wm: *mzterwm.WindowManager) void {
    self.columns.deinit(wm.globals.alloc);
}

fn onUserKey(_: *river.XkbBindingV1, ev: river.XkbBindingV1.Event, keydat: *KeyData) void {
    if (ev != .pressed) return;

    const cur_outp = keydat.wm.selectedOutput() orelse return;
    const ts = &(cur_outp.tag_space orelse return);
    std.debug.assert(ts.tagdata[ts.primary].layout == .scroll);
    const self = &ts.tagdata[ts.primary].layout.scroll;

    switch (keydat.action) {
        .set_direction => |to| {
            self.direction = to;
        },
        .resize_col => |by| {
            const col = self.findFocusedColOnAction(keydat.wm, ts) orelse return;
            col.size = @intCast(std.math.clamp(
                col.size +| by,
                min_col_size,
                max_col_size,
            ));
        },
        .adjust_nwins => |by| {
            const col = self.findFocusedColOnAction(keydat.wm, ts) orelse return;
            col.nwins = @max(col.nwins +| by, 1);
        },
        .scroll => |by| {
            self.scroll = @max(self.scroll + by, 0);
        },
        .scroll_directional => |by| {
            const actual_by = switch (self.direction) {
                .right, .down => by,
                .left, .up => -by,
            };

            self.scroll = @max(self.scroll + actual_by, 0);
        },
    }
}

fn findFocusedColOnAction(self: *Scroll, wm: *mzterwm.WindowManager, ts: *TagSpace) ?*Column {
    const focus_idx = focusColIdx(
        wm,
        ts.getVisibleWindows() catch @panic("OOM"),
        self.columns.items,
    ) orelse return null;

    if (focus_idx >= self.columns.items.len) {
        log.warn(
            "User tried to modify a virtual column!  This shouldn't be possible!  " ++
                "Focused column is idx {}, but we only have {}!",
            .{ focus_idx, self.columns.items.len },
        );
        return null;
    }

    return &self.columns.items[focus_idx];
}

pub fn performLayout(
    self: *Scroll,
    wm: *mzterwm.WindowManager,
    output_region: mzterwm.Region,
    windows: []const *mzterwm.WindowManager.Window,
) !void {
    if (windows.len == 0) return;

    const alloc = wm.globals.alloc;
    const outer_border = wm.config.gaps.output;

    const region: mzterwm.Region = switch (self.direction) {
        .right, .left => .{
            .pos = output_region.pos +| @as(Size, .{ 0, outer_border }),
            .size = output_region.size -| @as(Size, .{ 0, outer_border * 2 }),
        },
        .up, .down => .{
            .pos = output_region.pos +| @as(Size, .{ outer_border, 0 }),
            .size = output_region.size -| @as(Size, .{ outer_border * 2, 0 }),
        },
    };

    const axis_size = switch (self.direction) {
        .right, .left => region.size[0],
        .up, .down => region.size[1],
    };

    const new_col: Column = .{
        .size = axis_size / 2,
        .nwins = 1,
    };

    if (self.columns.items.len == 0) {
        // If we don't have any columns saved, we will end up needing as many as we have windows.
        log.debug("We have no columns yet, allocating for {} windows", .{windows.len});
        try self.columns.appendNTimes(alloc, new_col, windows.len);
    }

    // Update scroll such that the focused window is visible.
    scroll: {
        const focus_idx = focusColIdx(wm, windows, self.columns.items) orelse break :scroll;

        var axis_min: u31 = 0;
        for (0..focus_idx) |i| {
            axis_min += if (i < self.columns.items.len)
                self.columns.items[i].size
            else
                new_col.size;
        }

        const col_size = if (focus_idx < self.columns.items.len)
            self.columns.items[focus_idx].size
        else
            new_col.size;

        const axis_max = axis_min + col_size;

        const clipped_left = self.scroll >= axis_min;
        const clipped_right = self.scroll + axis_size <= axis_max;

        if (clipped_left and clipped_right) {
            // Window is wider than output and clipped on both sides, the user needs to scroll
            // manually.
        } else if (clipped_left) {
            if (col_size > axis_size) {
                // Column is larger than axis, scroll such that it's right edge is at the right
                // screen border.  This makes manual scrolling nicer.
                self.scroll = axis_max - axis_size;
            } else {
                // Column isn't larger than axis, scroll such that it's on the left screen border.
                self.scroll = axis_min;
            }
        } else if (clipped_right) {
            self.scroll = axis_max - axis_size;
        }
    }

    var col_i: usize = 0;
    var col = &self.columns.items[col_i];

    var in_col: u8 = 0;
    var axis_off: u31 = 0;
    for (windows) |win| {
        defer in_col += 1;

        if (in_col >= col.nwins) {
            in_col = 0;
            axis_off += col.size;

            col_i += 1;
            if (col_i >= self.columns.items.len) {
                // Append new columns such that col_i is the index of the last item.
                const needed = col_i - self.columns.items.len + 1;
                log.debug("Out of columns, allocating extra {}", .{needed});
                try self.columns.appendNTimes(alloc, new_col, needed);
            }
            col = &self.columns.items[col_i];
        }

        const axis_max = axis_off + col.size;

        // check if window is outside of visible area
        if (axis_max <= self.scroll or axis_off >= self.scroll + axis_size) {
            win.render.layout_hide = true;
            continue;
        }

        win.render.layout_hide = false;

        const orthsize = switch (self.direction) {
            .right, .left => region.size[1] / col.nwins,
            .up, .down => region.size[0] / col.nwins,
        };

        const winpos: Pos = switch (self.direction) {
            .right => .{ @as(i32, axis_off) - self.scroll, orthsize * in_col },
            .left => .{ @as(i32, axis_size) - axis_max + self.scroll, orthsize * (col.nwins - in_col - 1) },
            .up => .{ orthsize * (col.nwins - in_col - 1), @as(i32, axis_size) - axis_max + self.scroll },
            .down => .{ orthsize * in_col, @as(i32, axis_off) - self.scroll },
        };

        const winsize: Size = switch (self.direction) {
            .left, .right => .{ col.size, orthsize },
            .up, .down => .{ orthsize, col.size },
        };

        const winreg: mzterwm.Region = .{ .pos = region.pos + winpos, .size = winsize };
        win.render.updateRegion(winreg.inset(wm.config.gaps.window));

        const clip_left = self.scroll > axis_off;
        const clip_right = self.scroll + axis_size < axis_max;

        if (clip_left or clip_right) {
            // Need to clip.  Comments below assume right layout direction for simplicity.

            var pos: i32 = switch (self.direction) {
                // If this window is off the left side of the screen, the position is our scroll
                // relative to the column offset.
                // If not, we keep it the top-right window corner to not clip on the left.
                .right, .down => if (clip_left) @as(i32, self.scroll) - axis_off else 0,

                // If we have an inverted layout, the position is related to right clipping (which
                // will be on the left or top of the screen, logically).
                .left, .up => if (clip_right) axis_max - (self.scroll + axis_size) else 0,
            };
            pos -= wm.config.gaps.window;

            const size: u31 = switch (@as(packed struct { l: bool, r: bool }, .{
                .l = clip_left,
                .r = clip_right,
            })) {
                // If we're clipping on both sides, the window must be taking up the whole width.
                .{ .l = true, .r = true } => axis_size,

                // If we're clipping only on the left, the size reduction is analogous to the
                // position calculation above.
                .{ .l = true, .r = false } => col.size - if (clip_left)
                    self.scroll - axis_off
                else
                    0,

                // If we're clipping only on the right, we subtract the start of the column from the
                // right screen edge.
                .{ .l = false, .r = true } => self.scroll + axis_size - axis_off,
                .{ .l = false, .r = false } => unreachable,
            };

            const rect: mzterwm.Region = switch (self.direction) {
                .right, .left => .{ .pos = .{ pos, -@as(i32, wm.config.gaps.window) }, .size = .{ size, orthsize } },
                .up, .down => .{ .pos = .{ -@as(i32, wm.config.gaps.window), pos }, .size = .{ orthsize, size } },
            };

            win.render.updateClip(rect);
        } else {
            win.render.updateClip(.zero);
        }
    }

    if (self.columns.items.len > col_i + 1) {
        log.debug("We have extra unused columns, truncating to {}", .{col_i + 1});
        self.columns.shrinkRetainingCapacity(col_i + 1);
    }
}

/// Find the index of the column the focused window resides in, or null if the focused window isn't
/// in any column.
fn focusColIdx(
    wm: *mzterwm.WindowManager,
    wins: []const *mzterwm.WindowManager.Window,
    columns: []const Column,
) ?usize {
    const focused = wm.focused_window orelse return null;

    var col_i: usize = 0;
    var in_col: u8 = 0;

    for (wins) |win| {
        if (win == focused) return col_i;

        in_col += 1;
        const nwins = if (col_i < columns.len) columns[col_i].nwins else 1;
        if (in_col >= nwins) {
            col_i += 1;
            in_col = 0;
        }
    }

    return null;
}
