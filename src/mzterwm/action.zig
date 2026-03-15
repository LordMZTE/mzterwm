const std = @import("std");
const mzterwm = @import("../root.zig");

const WindowManager = @import("WindowManager.zig");

pub const Action = union(enum) {
    // These are in PascalCase for the Ziggy config to look nice.
    FocusWindow: struct { direction: FocusDirection },
    FocusOutput: struct { direction: FocusDirection },
    Spawn: struct { argv: []const []const u8 },

    pub fn perform(self: Action, wm: *WindowManager) !void {
        switch (self) {
            .FocusWindow => |opt| {
                const output = wm.selectedOutput() orelse return;
                const ts = &(output.tag_space orelse return);
                const wins = try ts.getWindows();

                switch (opt.direction) {
                    .next => mzterwm.rotFocusFwd(&ts.selected_window, wins.len),
                    .prev => mzterwm.rotFocusBck(&ts.selected_window, wins.len),
                }

                ts.windows_valid = false;
                try ts.commitFocus();
            },
            .FocusOutput => |opt| {
                switch (opt.direction) {
                    .next => mzterwm.rotFocusFwd(&wm.selected_output, wm.outputs.items.len),
                    .prev => mzterwm.rotFocusBck(&wm.selected_output, wm.outputs.items.len),
                }

                if (wm.selectedOutput()) |out|
                    if (out.tag_space) |*ts| try ts.commitFocus();
            },
            .Spawn => |opt| {
                const t = try std.Thread.spawn(.{}, spawnAndWaitChild, .{ wm.globals.alloc, opt.argv });
                t.detach();
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

pub const FocusDirection = enum { next, prev };
