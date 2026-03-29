const std = @import("std");
const mzterwm = @import("../root.zig");

const WindowManager = @import("WindowManager.zig");
const TagSpace = @import("TagSpace.zig");

pub const Action = union(enum) {
    // These are in PascalCase for the Ziggy config to look nice.
    FocusWindow: struct { direction: FocusDirection },
    FocusOutput: struct { direction: FocusDirection },
    MoveWindow: struct { direction: FocusDirection },
    MoveWindowOutput: struct { direction: FocusDirection },
    CloseWindow: struct {},
    ToggleWindowFullscreen: struct {},
    SetWindowTags: struct { to: TagSpace.Mask },
    AddWindowTags: struct { tags: TagSpace.Mask },
    Spawn: struct { argv: []const []const u8 },
    Quit: struct {},

    pub fn perform(self: Action, wm: *WindowManager) !void {
        switch (self) {
            .FocusWindow => |opt| {
                const output = wm.selectedOutput() orelse return;
                const ts = &(output.tag_space orelse return);

                switch (opt.direction) {
                    .next => try ts.maybeUpdateFocus(mzterwm.rotFocusFwd),
                    .prev => try ts.maybeUpdateFocus(mzterwm.rotFocusBck),
                }

                ts.windows_valid = false;
                try ts.commitFocus();
            },
            .FocusOutput => |opt| {
                if (wm.outputs.items.len < 2) return;

                switch (opt.direction) {
                    .next => mzterwm.rotFocusFwd(&wm.selected_output, wm.outputs.items.len),
                    .prev => mzterwm.rotFocusBck(&wm.selected_output, wm.outputs.items.len),
                }
                wm.selected_output_dirty = true;

                if (wm.selectedOutput()) |out|
                    if (out.tag_space) |*ts| try ts.commitFocus();
            },
            .MoveWindow => |opt| {
                const ts = &((wm.selectedOutput() orelse return).tag_space orelse return);
                const wins = try ts.getWindows();
                if (ts.selected_window >= wins.len or wins.len < 2) return;

                var other_idx = ts.selected_window;
                const wrap = switch (opt.direction) {
                    .next => mzterwm.rotFocusFwdCheckWrap(&other_idx, wins.len),
                    .prev => mzterwm.rotFocusBckCheckWrap(&other_idx, wins.len),
                };

                const this_win = wins[ts.selected_window];
                const other_win = wins[other_idx];
                wm.windows.remove(&this_win.winlist_node);
                switch (if (wrap) opt.direction.opposite() else opt.direction) {
                    .next => wm.windows.insertAfter(&other_win.winlist_node, &this_win.winlist_node),
                    .prev => wm.windows.insertBefore(&other_win.winlist_node, &this_win.winlist_node),
                }

                ts.selected_window = other_idx;
                ts.windows_valid = false;
            },
            .MoveWindowOutput => |opt| {
                if (wm.outputs.items.len < 2) return;
                const cur_outp = wm.selectedOutput() orelse return;
                const cur_ts = &(cur_outp.tag_space orelse return);

                const wins = try cur_ts.getWindows();
                if (cur_ts.selected_window >= wins.len) return;
                const win = wins[cur_ts.selected_window];

                var other_idx = wm.selected_output;
                switch (opt.direction) {
                    .next => mzterwm.rotFocusFwd(&other_idx, wm.outputs.items.len),
                    .prev => mzterwm.rotFocusBck(&other_idx, wm.outputs.items.len),
                }
                const other_outp = wm.outputs.items[other_idx];

                wm.moveWindowTo(win, other_outp);
            },
            .CloseWindow => {
                const outp = wm.selectedOutput() orelse return;
                const ts = &(outp.tag_space orelse return);
                const wins = try ts.getWindows();
                if (ts.selected_window >= wins.len) return;

                const cur_win = wins[ts.selected_window];

                // Set the window to be close-requested the next manage sequence.
                // One will start afterwards, since they're triggered by keybindings.
                // TODO: consider this once we make actions triggerable via IPC.
                cur_win.should_close = true;
            },
            .ToggleWindowFullscreen => {
                const outp = wm.selectedOutput() orelse return;
                const ts = &(outp.tag_space orelse return);
                const wins = try ts.getWindows();
                if (ts.selected_window >= wins.len) return;

                const cur_win = wins[ts.selected_window];

                cur_win.render.want_fullscreen = !cur_win.render.want_fullscreen;
                cur_win.render.dirty.want_fullscreen = true;
            },
            inline .SetWindowTags, .AddWindowTags => |opt, tag| {
                const outp = wm.selectedOutput() orelse return;
                const ts = &(outp.tag_space orelse return);
                const wins = try ts.getWindows();
                if (ts.selected_window >= wins.len) return;

                const cur_win = wins[ts.selected_window];
                if (comptime tag == .SetWindowTags) {
                    cur_win.mask = opt.to;
                } else {
                    cur_win.mask |= opt.tags;
                }
                ts.windows_valid = false;
                wm.notifyTagsChangedOn(outp);
            },
            .Spawn => |opt| {
                const t = try std.Thread.spawn(.{}, spawnAndWaitChild, .{ wm.globals.alloc, opt.argv });
                t.detach();
            },
            .Quit => {
                wm.globals.rwm.exitSession();
            },
        }
    }
};

fn spawnAndWaitChild(alloc: std.mem.Allocator, argv: []const []const u8) void {
    if (argv.len == 0) {
        std.log.err("can't spawn child with empty argv", .{});
        return;
    }

    var child: std.process.Child = .init(argv, alloc);
    const term = child.spawnAndWait() catch |e| {
        std.log.warn("failed to spawn child process `{s}`: {}", .{ argv[0], e });
        return;
    };
    std.log.debug("child exited with {}", .{term});
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
