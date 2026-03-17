const mzterwm = @import("../root.zig");

pub const Focus = @import("layout/Focus.zig");

pub const Layout = union(enum) {
    focus: Focus,

    pub fn performLayout(
        self: *Layout,
        wm: *mzterwm.WindowManager,
        region: mzterwm.Region,
        windows: []const *mzterwm.WindowManager.Window,
    ) !void {
        return switch (self.*) {
            inline else => |*delegate| delegate.performLayout(wm, region, windows),
        };
    }
};

pub const LayoutKind = @typeInfo(Layout).@"union".tag_type.?;
