const std = @import("std");
const mzterwm = @import("../root.zig");

const layout = @import("layout.zig");

const WindowManager = @import("WindowManager.zig");
const TagSpace = @import("TagSpace.zig");

pub const Action = union(enum) {
    focus_window: FocusDirection,
    focus_output: FocusDirection,
    move_window: FocusDirection,
    move_window_output: FocusDirection,
    swap_top,
    close_window,
    toggle_window_fullscreen,
    set_window_tags: TagSpace.Mask,
    add_window_tags: TagSpace.Mask,
    spawn: []const []const u8,
    rotate_layout: FocusDirection,
    quit,

    pub fn perform(self: Action, wm: *WindowManager) !void {
        switch (self) {
            .focus_window => |direction| {
                const output = wm.selectedOutput() orelse return;
                const ts = &(output.tag_space orelse return);

                switch (direction) {
                    .next => try ts.maybeUpdateFocus(mzterwm.rotFocusFwd),
                    .prev => try ts.maybeUpdateFocus(mzterwm.rotFocusBck),
                }

                ts.visible_windows_valid = false;
                try ts.commitFocusCurrentOutput();
            },
            .focus_output => |direction| {
                if (wm.outputs.items.len < 2) return;

                switch (direction) {
                    .next => mzterwm.rotFocusFwd(usize, &wm.selected_output, wm.outputs.items.len - 1),
                    .prev => mzterwm.rotFocusBck(usize, &wm.selected_output, wm.outputs.items.len - 1),
                }
                wm.selected_output_dirty = true;

                if (wm.selectedOutput()) |out|
                    if (out.tag_space) |*ts| try ts.commitFocusCurrentOutput();
            },
            .move_window => |direction| {
                const ts = &((wm.selectedOutput() orelse return).tag_space orelse return);
                const wins = try ts.getVisibleWindows();
                if (ts.selected_window >= wins.len or wins.len < 2) return;

                var other_idx = ts.selected_window;
                const wrap = switch (direction) {
                    .next => mzterwm.rotFocusFwdCheckWrap(usize, &other_idx, wins.len - 1),
                    .prev => mzterwm.rotFocusBckCheckWrap(usize, &other_idx, wins.len - 1),
                };

                const this_win = wins[ts.selected_window];
                const other_win = wins[other_idx];
                wm.windows.remove(&this_win.winlist_node);
                switch (if (wrap) direction.opposite() else direction) {
                    .next => wm.windows.insertAfter(&other_win.winlist_node, &this_win.winlist_node),
                    .prev => wm.windows.insertBefore(&other_win.winlist_node, &this_win.winlist_node),
                }

                // No need to call onSelectedWindowChanged, because we moved the window as well as
                // changing selected_window.
                ts.selected_window = other_idx;
                ts.visible_windows_valid = false;
            },
            .move_window_output => |direction| {
                if (wm.outputs.items.len < 2) return;
                const cur_outp = wm.selectedOutput() orelse return;
                const cur_ts = &(cur_outp.tag_space orelse return);

                const wins = try cur_ts.getVisibleWindows();
                if (cur_ts.selected_window >= wins.len) return;
                const win = wins[cur_ts.selected_window];

                var other_idx = wm.selected_output;
                switch (direction) {
                    .next => mzterwm.rotFocusFwd(usize, &other_idx, wm.outputs.items.len - 1),
                    .prev => mzterwm.rotFocusBck(usize, &other_idx, wm.outputs.items.len - 1),
                }
                const other_outp = wm.outputs.items[other_idx];

                try wm.moveWindowTo(.{
                    .win = win,
                    .to = other_outp,
                });
            },
            .swap_top => {
                const ts = &((wm.selectedOutput() orelse return).tag_space orelse return);
                const wins = try ts.getVisibleWindows();
                if (wins.len < 2) return;

                if (ts.selected_window == 0) {
                    // If the topmost window is selected, swap it with the one below it.
                    wm.windows.remove(&wins[1].winlist_node);
                    wm.windows.insertBefore(&wins[0].winlist_node, &wins[1].winlist_node);
                    try ts.onSelectedWindowChanged();
                } else if (ts.selected_window < wins.len) {
                    // Otherwise, move the currently focused window to the top and focus that.
                    wm.windows.remove(&wins[ts.selected_window].winlist_node);
                    wm.windows.insertBefore(
                        &wins[0].winlist_node,
                        &wins[ts.selected_window].winlist_node,
                    );
                    ts.selected_window = 0;
                    try ts.onSelectedWindowChanged();
                }
                ts.visible_windows_valid = false;
                try ts.commitFocusCurrentOutput();
            },
            .close_window => {
                const outp = wm.selectedOutput() orelse return;
                const ts = &(outp.tag_space orelse return);
                const wins = try ts.getVisibleWindows();
                if (ts.selected_window >= wins.len) return;

                const cur_win = wins[ts.selected_window];

                // Set the window to be close-requested the next manage sequence.
                // One will start afterwards, since they're triggered by keybindings.
                // TODO: consider this once we make actions triggerable via IPC.
                cur_win.should_close = true;
            },
            .toggle_window_fullscreen => {
                const outp = wm.selectedOutput() orelse return;
                const ts = &(outp.tag_space orelse return);
                const wins = try ts.getVisibleWindows();
                if (ts.selected_window >= wins.len) return;

                const cur_win = wins[ts.selected_window];

                cur_win.render.want_fullscreen = !cur_win.render.want_fullscreen;
                cur_win.render.dirty.want_fullscreen = true;
            },
            inline .set_window_tags, .add_window_tags => |tags, tag| {
                const outp = wm.selectedOutput() orelse return;
                const ts = &(outp.tag_space orelse return);
                const wins = try ts.getVisibleWindows();
                if (ts.selected_window >= wins.len) return;

                const cur_win = wins[ts.selected_window];
                if (comptime tag == .set_window_tags) {
                    cur_win.mask = tags;
                } else {
                    cur_win.mask |= tags;
                }
                ts.visible_windows_valid = false;
                wm.notifyTagsChangedOn(outp);
                wm.ipc.flushAll();
            },
            .spawn => |argv| {
                try wm.longgrp.concurrent(
                    wm.globals.io,
                    spawnAndWaitChild,
                    .{ wm.globals.io, argv, wm.child_env },
                );
            },
            .rotate_layout => |direction| {
                const cur_outp = wm.selectedOutput() orelse return;
                const ts = &(cur_outp.tag_space orelse return);
                const current_layout: layout.LayoutKind = ts.tagdata[ts.primary].layout;

                var cur_n = @intFromEnum(current_layout);
                const max = @typeInfo(layout.LayoutKind).@"enum".fields.len - 1;

                switch (direction) {
                    .next => mzterwm.rotFocusFwd(@TypeOf(cur_n), &cur_n, max),
                    .prev => mzterwm.rotFocusBck(@TypeOf(cur_n), &cur_n, max),
                }

                const new_kind: layout.LayoutKind = @enumFromInt(cur_n);

                try ts.tagdata[ts.primary].swapLayout(new_kind, wm);

                wm.updateActiveLayout();
            },
            .quit => {
                wm.globals.rwm.exitSession();
            },
        }
    }
};

fn spawnAndWaitChild(
    io: std.Io,
    argv: []const []const u8,
    env: *const std.process.Environ.Map,
) std.Io.Cancelable!void {
    if (argv.len == 0) {
        std.log.err("can't spawn child with empty argv", .{});
        return;
    }

    var child = std.process.spawn(io, .{
        .argv = argv,
        .environ_map = env,
    }) catch |e| switch (e) {
        error.Canceled => return error.Canceled,
        else => {
            std.log.warn("failed to spawn child process `{s}`: {}", .{ argv[0], e });
            return;
        },
    };

    const term = child.wait(io) catch |e| switch (e) {
        error.Canceled => return error.Canceled,
        else => {
            std.log.warn("failed to wait for child process `{s}`: {}", .{ argv[0], e });
            return;
        },
    };

    std.log.debug("child `{s}` exited with {}", .{ argv[0], term });
}

pub const FocusDirection = enum {
    next,
    prev,

    pub fn opposite(self: FocusDirection) FocusDirection {
        return switch (self) {
            .next => .prev,
            .prev => .next,
        };
    }
};
