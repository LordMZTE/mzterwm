const mzterwm = @import("../root.zig");

pub const Layout = union(enum) {
    focus: @import("layout/Focus.zig"),

    pub fn performLayout(
        self: *Layout,
        wm: *mzterwm.WindowManager,
        region: mzterwm.Region,
        windows: []const usize,
    ) !void {
        return switch (self.*) {
            inline else => |*delegate| delegate.performLayout(wm, region, windows),
        };
    }
};
