//! A TagSpace is a data structure that holds windows that reside in a set of tags, managing which
//! tags are selected and data associated with them.

const std = @import("std");
const proto = @import("mzterwm-proto");
const mzterwm = @import("../root.zig");

const Layout = @import("layout.zig").Layout;
const WindowManager = @import("WindowManager.zig");

pub const bitwidth = proto.tag_bitwidth;
pub const Mask = proto.TagMask;
pub const TagIdx = proto.TagIdx;

/// The parent window manager
wm: *WindowManager,

/// The mask of currently selected tags
mask: Mask,

/// The tag that is currently considered primary.  This must be one that is also in mask.
primary: TagIdx,

/// Per-tag data.  This is typically indexed by the primary tag.
tagdata: [bitwidth]TagData,

/// Windows in this TagSpace.  This is a sublist of indices into wm.windows.
/// This should only be considered meaningful if windows_valid is true.  Otherwise, it must be
/// recomputed.
windows: std.ArrayList(*WindowManager.Window),
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
    for (&self.tagdata) |*dat| {
        dat.deinit();
    }
    self.windows.deinit(self.wm.globals.alloc);
}

pub fn evacuateTo(self: *TagSpace, other: ?*TagSpace) !void {
    for (try self.getWindows()) |win| {
        if (win.render.is_fullscreen) {
            // River unfullscreens windows on output disconnect.
            win.render.dirty.is_fullscreen = true;
        }

        win.tag_space = other;
    }
    if (other) |o| o.windows_valid = false;
    self.windows_valid = false;
}

/// Gets or computes the list of window indices in this TagSpace.
pub fn getWindows(self: *TagSpace) std.mem.Allocator.Error![]*WindowManager.Window {
    if (self.windows_valid) return self.windows.items;

    self.windows.clearRetainingCapacity();

    var maybe_node = self.wm.windows.first;
    while (maybe_node) |node| : (maybe_node = node.next) {
        const win: *WindowManager.Window = .fromListNode(node);

        if (win.tag_space != self or win.mask & self.mask == 0) continue;

        try self.windows.append(self.wm.globals.alloc, win);
    }

    self.windows_valid = true;
    return self.windows.items;
}

/// Tells River to actually focus the currently selected window.  Unfocuses any focused window if
/// there is no selected window.
pub fn commitFocus(self: *TagSpace) std.mem.Allocator.Error!void {
    switch (self.wm.focus_override) {
        .none => {},
        .exclusive => return,
        .non_exclusive => {
            self.wm.focus_override = .none;
            self.wm.onFocusOverrideChanged();
        },
    }
    if (self.wm.focus_override != .none) return;

    const wins = try self.getWindows();
    self.wm.focused_window = find_win: {
        if (wins.len == 1 and wins[0].render.want_fullscreen) break :find_win wins[0];

        if (self.selected_window >= wins.len) {
            self.wm.unfocus();
            return;
        }

        break :find_win wins[self.selected_window];
    };

    self.wm.focused_window_dirty = true;

    self.wm.updateActiveLayout();
}

pub fn maybeUpdateFocus(self: *TagSpace, comptime rotFn: fn (*usize, usize) void) !void {
    switch (self.wm.focus_override) {
        .none => {
            const wins = try self.getWindows();
            rotFn(&self.selected_window, wins.len);
            self.windows_valid = false;
            try self.commitFocus();
            try self.onSelectedWindowChanged();
        },
        .non_exclusive => {
            const wins = try self.getWindows();
            rotFn(&self.selected_window, wins.len);
            self.wm.focus_override = .none;
            self.wm.onFocusOverrideChanged();
            try self.commitFocus();
            try self.onSelectedWindowChanged();
        },
        .exclusive => {},
    }
}

pub fn computeOccupiedTags(self: *TagSpace) Mask {
    var occupied: TagSpace.Mask = 0;
    var maybe_node = self.wm.windows.first;
    while (maybe_node) |node| : (maybe_node = node.next) {
        const win: *WindowManager.Window = .fromListNode(node);
        if (win.tag_space != self) continue;
        occupied |= win.mask;
    }
    return occupied;
}

pub fn focusedWindow(self: *TagSpace) std.mem.Allocator.Error!?*WindowManager.Window {
    const wins = try self.getWindows();
    if (self.selected_window >= wins.len) return null;
    return wins[self.selected_window];
}

/// Should be called when the window that is selected within this tag space changes.
/// Possible causes:
/// - selected_window was updated without the windows moving accordingly
/// - the tag mask was changed
/// - the focused window was closed, or a new window was added at the current focused index.
pub fn onSelectedWindowChanged(self: *TagSpace) std.mem.Allocator.Error!void {
    const output = self.wm.findOutputForTagSpace(self) orelse return;
    const name = output.name() orelse return;

    const maybe_focus_win = try self.focusedWindow();

    self.wm.ipc.emitEventToAll(.{ .title_change = .{
        .title = if (maybe_focus_win) |focus| focus.title.items else "",
        .output = name,
    } });
}
