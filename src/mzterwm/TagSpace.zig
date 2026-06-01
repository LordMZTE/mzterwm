//! A TagSpace is a data structure that holds windows that reside in a set of tags, managing which
//! tags are selected and data associated with them.

const std = @import("std");
const proto = @import("mzterwm-proto");
const mzterwm = @import("../root.zig");

const layout = @import("layout.zig");
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

/// Visible windows in this TagSpace.  This is a sublist of wm.windows.
/// This should only be considered meaningful if visible_windows_valid is true.  Otherwise, it must be
/// recomputed.
/// If you want to use this, you should consider calling getVisibleWindows instead, which will
/// lazily recompute the list if needed.
visible_windows: std.ArrayList(*WindowManager.Window),
visible_windows_valid: bool,

/// Index of the window that is currently selected in windows.
/// It's allowed for this to be out-of-bounds, in which case no window is selected.
selected_window: usize,

const TagSpace = @This();

pub const TagData = struct {
    /// The layout of this tag
    layout: layout.Layout,

    pub const init: TagData = .{
        .layout = .{ .focus = .init_val },
    };

    pub fn swapLayout(self: *TagData, to: layout.LayoutKind, wm: *mzterwm.WindowManager) !void {
        if (self.layout == to) return;

        const new = switch (to) {
            inline else => |to_ct| @unionInit(layout.Layout, @tagName(to_ct), try .init(wm)),
        };
        self.layout.deinit(wm);
        self.layout = new;
    }

    pub fn deinit(self: *TagData, wm: *mzterwm.WindowManager) void {
        self.layout.deinit(wm);
    }
};

pub fn init(wm: *WindowManager) TagSpace {
    return .{
        .wm = wm,
        .mask = 1,
        .primary = 0,
        .tagdata = @splat(.init),
        .visible_windows = .empty,
        .visible_windows_valid = false,
        .selected_window = 0,
    };
}

pub fn deinit(self: *TagSpace) void {
    for (&self.tagdata) |*dat| {
        dat.deinit(self.wm);
    }
    self.visible_windows.deinit(self.wm.globals.alloc);
}

pub fn evacuateTo(self: *TagSpace, other: ?*TagSpace) !void {
    var maybe_node = self.wm.windows.first;
    while (maybe_node) |node| : (maybe_node = node.next) {
        const win: *WindowManager.Window = .fromListNode(node);
        if (win.tag_space != self) continue;

        if (win.render.is_fullscreen) {
            // River unfullscreens windows on output disconnect.
            win.render.dirty.is_fullscreen = true;
        }

        win.tag_space = other;

        if (win.render.is_fullscreen) {
            // Need to make another fullscreen request to update output
            win.render.dirty.is_fullscreen = true;
        }
    }
    if (other) |o| {
        o.visible_windows_valid = false;
        if (self.wm.findOutputForTagSpace(o)) |outp| {
            self.wm.notifyTagsChangedOn(outp);
            self.wm.ipc.flushAll();
        }
    }
    self.visible_windows_valid = false;
}

/// Gets or computes the list of currentl visible windows in this TagSpace.
pub fn getVisibleWindows(self: *TagSpace) std.mem.Allocator.Error![]*WindowManager.Window {
    if (self.visible_windows_valid) return self.visible_windows.items;

    self.visible_windows.clearRetainingCapacity();

    var maybe_node = self.wm.windows.first;
    while (maybe_node) |node| : (maybe_node = node.next) {
        const win: *WindowManager.Window = .fromListNode(node);

        if (win.tag_space != self or win.mask & self.mask == 0) continue;

        try self.visible_windows.append(self.wm.globals.alloc, win);
    }

    self.visible_windows_valid = true;
    return self.visible_windows.items;
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
    for (self.wm.outputs.items, 0..) |other_outp, i| {
        if (other_outp.tag_space != null and &other_outp.tag_space.? == self) {
            if (self.wm.selected_output != i) {
                self.wm.selected_output = i;
                self.wm.onSelectedOutputChanged();
            }

            break;
        }
    } else {
        std.log.err("Attempt to commitFocus for {*} doesn't belong to any output.", .{self});
        return;
    }

    try self.commitFocusInner();
}

/// Like `commitFocus`, but more efficient if this TagSpace's output is already selected.
/// Caller asserts that the current output is this tag space's output.
pub fn commitFocusCurrentOutput(self: *TagSpace) std.mem.Allocator.Error!void {
    if (@import("builtin").mode == .Debug) {
        const this_outp = self.wm.findOutputForTagSpace(self);
        const cur_outp = self.wm.selectedOutput();
        std.debug.assert(this_outp == cur_outp);
    }

    switch (self.wm.focus_override) {
        .none => {},
        .exclusive => return,
        .non_exclusive => {
            self.wm.focus_override = .none;
            self.wm.onFocusOverrideChanged();
        },
    }
    if (self.wm.focus_override != .none) return;

    try self.commitFocusInner();
}

fn commitFocusInner(self: *TagSpace) std.mem.Allocator.Error!void {
    const wins = try self.getVisibleWindows();
    const new_focus = find_win: {
        if (wins.len == 1 and wins[0].render.want_fullscreen) break :find_win wins[0];

        if (self.selected_window >= wins.len) {
            self.wm.unfocus();
            return;
        }

        break :find_win wins[self.selected_window];
    };

    if (new_focus != self.wm.focused_window) {
        self.wm.focused_window = new_focus;
        if (self.wm.focused_window_dirty == .no)
            self.wm.focused_window_dirty = .yes;
    }
}

pub fn maybeUpdateFocus(self: *TagSpace, comptime rotFn: mzterwm.RotFn) !void {
    switch (self.wm.focus_override) {
        .none => {
            const wins = try self.getVisibleWindows();
            if (wins.len == 0) return;
            rotFn(usize, &self.selected_window, wins.len - 1);
            self.visible_windows_valid = false;
            try self.commitFocusCurrentOutput();
            try self.onSelectedWindowChanged();
        },
        .non_exclusive => {
            const wins = try self.getVisibleWindows();
            if (wins.len == 0) return;
            rotFn(usize, &self.selected_window, wins.len - 1);
            self.wm.focus_override = .none;
            self.wm.onFocusOverrideChanged();
            try self.commitFocusCurrentOutput();
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
    const wins = try self.getVisibleWindows();
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
    self.wm.ipc.flushAll();
}
