///! State of global objects that is kept around for the entire program.
const std = @import("std");
const wayland = @import("wayland");
const mzterwm = @import("../root.zig");

const wl = wayland.client.wl;
const river = wayland.client.river;

/// An allocator which is stored here so we can make allocations from the registry listener.
alloc: std.mem.Allocator,
rwm: *river.WindowManagerV1,
xkb_binds: *river.XkbBindingsV1,
outputs: std.ArrayList(Output),

const Globals = @This();

const PartialOrGlobals = union(enum) {
    partial: struct {
        alloc: std.mem.Allocator,
        rwm: ?*river.WindowManagerV1 = null,
        xkb_binds: ?*river.XkbBindingsV1 = null,
        outputs: std.ArrayList(Output) = .empty,
    },
    globals: Globals,
};

/// Collects initial globals into the structure and then installs a long-lived registry handler.
pub fn setupListenerAndCollect(
    alloc: std.mem.Allocator,
    reg: *wl.Registry,
    dpy: *wl.Display,
) !*Globals {
    const pog = try alloc.create(PartialOrGlobals);
    errdefer alloc.destroy(pog);

    pog.* = .{
        .partial = .{ .alloc = alloc },
    };

    const self: Globals = initial: {
        errdefer {
            if (pog.partial.rwm) |it| it.destroy();
            for (pog.partial.outputs.items) |it| {
                it.deinit();
            }
            pog.partial.outputs.deinit(alloc);
        }

        reg.setListener(*PartialOrGlobals, regListener, pog);
        try mzterwm.roundtrip(dpy);
        break :initial .{
            .alloc = alloc,
            .rwm = pog.partial.rwm orelse
                return complainAboutMissingGlobal(river.WindowManagerV1),
            .xkb_binds = pog.partial.xkb_binds orelse
                return complainAboutMissingGlobal(river.XkbBindingsV1),
            .outputs = pog.partial.outputs,
        };
    };
    pog.* = .{ .globals = self };

    return &pog.globals;
}

fn complainAboutMissingGlobal(comptime T: type) error{MissingGlobal} {
    std.log.err("missing required global {s}", .{T.interface.name});
    return error.MissingGlobal;
}

fn regListener(reg: *wl.Registry, ev: wl.Registry.Event, pog: *PartialOrGlobals) void {
    switch (ev) {
        .global => |g| switch (pog.*) {
            .partial => |*self| {
                if (std.mem.orderZ(u8, g.interface, wl.Output.interface.name) == .eq) {
                    self.outputs.append(self.alloc, .{
                        .name = g.name,
                        .wl = reg.bind(
                            g.name,
                            wl.Output,
                            wl.Output.generated_version,
                        ) catch @panic("OOM"),
                    }) catch @panic("OOM");
                } else if (std.mem.orderZ(u8, g.interface, river.WindowManagerV1.interface.name) == .eq) {
                    self.rwm = reg.bind(
                        g.name,
                        river.WindowManagerV1,
                        river.WindowManagerV1.generated_version,
                    ) catch @panic("OOM");
                } else if (std.mem.orderZ(u8, g.interface, river.XkbBindingsV1.interface.name) == .eq) {
                    self.xkb_binds = reg.bind(
                        g.name,
                        river.XkbBindingsV1,
                        river.XkbBindingsV1.generated_version,
                    ) catch @panic("OOM");
                }
            },
            .globals => |*self| {
                if (std.mem.orderZ(u8, g.interface, river.WindowManagerV1.interface.name) == .eq) {
                    self.rwm = reg.bind(
                        g.name,
                        river.WindowManagerV1,
                        river.WindowManagerV1.generated_version,
                    ) catch @panic("OOM");
                }
            },
        },
        .global_remove => |g| {
            const outputs = switch (pog.*) {
                inline else => |*self| &self.outputs,
            };

            for (outputs.items, 0..) |output, i| {
                if (output.name == g.name) {
                    outputs.swapRemove(i).deinit();
                    break;
                }
            }
        },
    }
}

pub fn deinit(self: *Globals) void {
    self.rwm.destroy();

    for (self.outputs.items) |it| {
        it.deinit();
    }

    self.outputs.deinit(self.alloc);

    const pog: *PartialOrGlobals = @fieldParentPtr("globals", self);
    self.alloc.destroy(pog);
}

/// State associated with an output
pub const Output = struct {
    name: u32,
    wl: *wl.Output,

    pub fn deinit(self: Output) void {
        self.wl.destroy();
    }
};
