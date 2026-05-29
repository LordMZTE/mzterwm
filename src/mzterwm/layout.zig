const mzterwm = @import("../root.zig");

pub const Focus = @import("layout/Focus.zig");
pub const Scroll = @import("layout/Scroll.zig");

pub const Layout = union(enum) {
    focus: Focus,
    scroll: Scroll,

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

    pub fn deinit(self: *Layout, wm: *mzterwm.WindowManager) void {
        return switch (self.*) {
            inline else => |*delegate| delegate.deinit(wm),
        };
    }
};

pub const LayoutKind = @typeInfo(Layout).@"union".tag_type.?;
