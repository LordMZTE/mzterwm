//! The focus layout is similar to the old rivertile from river-classic.
//! There is one column with the "primary" window, all other windows being moved to the other column
//! where they are stacked orthogonally.

const mzterwm = @import("../../root.zig");

const Focus = @This();

primary_ratio: mzterwm.Ratio,
direction: mzterwm.Cardinal,

pub const init: Focus = .{
    .primary_ratio = .half,
    .direction = .row,
};

pub fn performLayout(
    self: *Focus,
    wm: *mzterwm.WindowManager,
    region: mzterwm.Region,
    windows: []const usize,
) !void {
    if (windows.len == 0) return;
    if (windows.len == 1) {
        wm.windows.items[windows[0]].render.updateRegion(region);
        return;
    }

    const primary, const secondary = region.slice(self.primary_ratio, self.direction);

    wm.windows.items[windows[0]].render.updateRegion(primary);

    const secondary_off = switch (self.direction) {
        .row => secondary.size[1] / @as(u31, @truncate(windows.len - 1)),
        .col => secondary.size[0] / @as(u31, @truncate(windows.len - 1)),
    };
    const secondary_size: [2]u31 = switch (self.direction) {
        .row => .{ secondary.size[0], secondary_off },
        .col => .{ secondary_off, secondary.size[1] },
    };

    for (windows[1..], 0..) |winid, i_usize| {
        const i: u31 = @truncate(i_usize);
        const secondary_region: mzterwm.Region = switch (self.direction) {
            .row => .{
                .pos = .{ secondary.pos[0], secondary.pos[1] + secondary_off * i },
                .size = secondary_size,
            },
            .col => .{
                .pos = .{ secondary.pos[0] + secondary_off * i, secondary.pos[1] },
                .size = secondary_size,
            },
        };

        wm.windows.items[winid].render.updateRegion(secondary_region);
    }
}
