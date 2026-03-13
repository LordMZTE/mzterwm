//! A TagSpace is a data structure that holds windows that reside in a set of tags, managing which
//! tags are selected and data associated with them.

const std = @import("std");

const Layout = @import("layout.zig").Layout;
const WindowManager = @import("WindowManager.zig");

pub const bitwidth = 32;
pub const Mask = std.meta.Int(.unsigned, bitwidth);

/// The parent window manager
wm: *WindowManager,

/// The mask of currently selected tags
mask: Mask,

/// The tag that is currently considered primary.  This must be one that is also in mask.
primary: std.math.Log2Int(Mask),

/// Per-tag data.  This is typically indexed by the primary tag.
tagdata: [bitwidth]TagData,

/// Windows in this TagSpace.  This is a sublist of indices into wm.windows.
/// This should only be considered meaningful if windows_valid is true.  Otherwise, it must be
/// recomputed.
windows: std.ArrayList(usize),
windows_valid: bool,

/// Index of the window that is currently selected in windows.
/// It's allowed for this to be out-of-bounds, in which case no window is selected.
selected_window: usize,

const TagSpace = @This();

pub const TagData = struct {
    /// The layout of this tag
    layout: Layout,

    pub const init: TagData = .{
        .layout = .{ .focus = .init },
    };

    pub fn deinit(self: *TagData) void {
        _ = self;
        //self.layout.deinit();
    }
};

pub fn init(wm: *WindowManager) TagSpace {
    return .{
        .wm = wm,
        .mask = 1,
        .primary = 0,
        .tagdata = @splat(.init),
        .windows = .empty,
        .windows_valid = false,
        .selected_window = 0,
    };
}

pub fn deinit(self: *TagSpace) void {
    for (self.tagdata) |dat| {
        dat.deinit();
    }

    for (self.windows.items) |win| {
        win.deinit();
    }
    self.windows.deinit(self.wm.globals.alloc);
}

pub fn evacuateTo(self: *TagSpace, other: ?*TagSpace) !void {
    for (try self.getWindows()) |winid| {
        self.wm.windows.items[winid].tag_space = other;
    }
    if (other) |o| o.windows_valid = false;
    self.windows_valid = false;
}

/// Gets or computes the list of window indices in this TagSpace
pub fn getWindows(self: *TagSpace) ![]usize {
    if (self.windows_valid) return self.windows.items;

    self.windows.clearRetainingCapacity();
    for (self.wm.windows.items, 0..) |win, i| {
        if (win.tag_space == self and win.mask & self.mask != 0) {
            try self.windows.append(self.wm.globals.alloc, i);
        }
    }

    self.windows_valid = true;
    return self.windows.items;
}
