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
outputs: std.SinglyLinkedList,

const Globals = @This();

const PartialOrGlobals = union(enum) {
    partial: struct {
        alloc: std.mem.Allocator,
        rwm: ?*river.WindowManagerV1 = null,
        xkb_binds: ?*river.XkbBindingsV1 = null,
        outputs: std.SinglyLinkedList = .{},
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
            var maybe_node = pog.partial.outputs.first;
            while (maybe_node) |node| : (maybe_node = node.next) {
                Output.fromListNode(node).deinit();
            }
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
                    const outp = self.alloc.create(Output) catch @panic("OOM");
                    outp.* = .{
                        .node = .{},
                        .name = g.name,
                        .wl = reg.bind(
                            g.name,
                            wl.Output,
                            wl.Output.generated_version,
                        ) catch @panic("OOM"),
                        .alloc = self.alloc,
                        .outp_name = null,
                        .wm_output = null,
                    };
                    outp.wl.setListener(*Output, Output.onEvent, outp);
                    self.outputs.prepend(&outp.node);
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
                if (std.mem.orderZ(u8, g.interface, wl.Output.interface.name) == .eq) {
                    const outp = self.alloc.create(Output) catch @panic("OOM");
                    outp.* = .{
                        .node = .{},
                        .name = g.name,
                        .wl = reg.bind(
                            g.name,
                            wl.Output,
                            wl.Output.generated_version,
                        ) catch @panic("OOM"),
                        .alloc = self.alloc,
                        .outp_name = null,
                        .wm_output = null,
                    };
                    outp.wl.setListener(*Output, Output.onEvent, outp);
                    self.outputs.prepend(&outp.node);
                }
            },
        },
        .global_remove => |g| {
            var outputs = switch (pog.*) {
                inline else => |*self| &self.outputs,
            };

            var maybe_node = outputs.first;
            while (maybe_node) |node| : (maybe_node = node.next) {
                const output: *Output = .fromListNode(node);
                if (output.name == g.name) {
                    outputs.remove(node);
                    output.deinit();
                    std.log.info("removed output {?s}", .{output.outp_name});
                    break;
                }
            }
        },
    }
}

pub fn deinit(self: *Globals) void {
    self.rwm.destroy();
    self.xkb_binds.destroy();

    var maybe_node = self.outputs.first;
    while (maybe_node) |node| {
        const outp = Output.fromListNode(node);
        maybe_node = outp.node.next;
        outp.deinit();
    }

    const pog: *PartialOrGlobals = @fieldParentPtr("globals", self);
    self.alloc.destroy(pog);
}

/// State associated with an output
pub const Output = struct {
    node: std.SinglyLinkedList.Node,
    name: u32,
    wl: *wl.Output,
    alloc: std.mem.Allocator,
    outp_name: ?[]const u8,

    /// See comment on WindowManager.Output.wl_output
    wm_output: ?*mzterwm.WindowManager.Output,

    pub fn deinit(self: *Output) void {
        self.wl.release();
        if (self.outp_name) |name| self.alloc.free(name);
        if (self.wm_output) |wm| wm.wl_output = null;
        self.alloc.destroy(self);
    }

    pub fn fromListNode(node: *std.SinglyLinkedList.Node) *Output {
        return @fieldParentPtr("node", node);
    }

    fn onEvent(_: *wl.Output, ev: wl.Output.Event, self: *Output) void {
        switch (ev) {
            .geometry => {},
            .mode => {},
            .done => {},
            .scale => {},
            .name => |data| {
                const new_name = self.alloc.dupe(u8, std.mem.span(data.name)) catch @panic("OOM");
                if (self.outp_name) |old_name| self.alloc.free(old_name);
                self.outp_name = new_name;
                std.log.info("new output name: {s}", .{new_name});

                if (self.wm_output) |wm| {
                    wm.onNameKnown();
                }
            },
            .description => {},
        }
    }
};
