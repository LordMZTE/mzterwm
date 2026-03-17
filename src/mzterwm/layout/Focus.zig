//! The focus layout is similar to the old rivertile from river-classic.
//! There is one column with the "primary" window, all other windows being moved to the other column
//! where they are stacked orthogonally.

const mzterwm = @import("../../root.zig");

const Focus = @This();

primary_ratio: mzterwm.Ratio,
direction: mzterwm.Cardinal,

pub const init: Focus = .{
    .primary_ratio = .half,
    .direction = .left,
};

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
