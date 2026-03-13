//! The global window manager state.  This struct is self-referential, do not move it.

const std = @import("std");
const wayland = @import("wayland");

const Globals = @import("Globals.zig");
const TagSpace = @import("TagSpace.zig");
const Region = @import("../root.zig").Region;

const river = wayland.client.river;

globals: *Globals,
run_state: enum {
    keep_running,
    errored,
    graceful_shutdown,
} = .keep_running,
outputs: std.ArrayList(*Output) = .empty,
windows: std.ArrayList(*Window) = .empty,

// Index into `outputs` for the currently selected output.  This always has to be in bounds.
selected_output: usize = 0,

pub const Output = struct {
    wm: *WindowManager,
    river: *river.OutputV1,
    region: Region,
    wl_output_name: u32,
    tag_space: TagSpace,

    pub fn deinit(self: *Output) void {
        self.river.destroy();
        self.wm.globals.alloc.destroy(self);
    }

    fn listener(_: *river.OutputV1, ev: river.OutputV1.Event, self: *Output) void {
        switch (ev) {
            .removed => {
                if (self.wm.outputs.items.len <= 1) @panic("last output removed");

                // If we have the last output in our list selected, then would end up with the index
                // being out-of-bounds.  Shift it over by one, so we still have the same output
                // selected as before.  If the last one also happens to be the one being removed,
                // we'll and up selecting the output before that which is also fine.
                if (self.wm.selected_output >= self.wm.outputs.items.len) {
                    self.wm.selected_output = self.wm.outputs.items.len - 1;
                }

                for (self.wm.outputs.items, 0..) |other, i| {
                    if (other == self) {
                        const old = self.wm.outputs.orderedRemove(i);
                        defer old.deinit();

                        old.tag_space.evacuateTo(
                            &self.wm.outputs.items[self.wm.selected_output].tag_space,
                        ) catch @panic("OOM");

                        break;
                    }
                }
            },
            .wl_output => |wlo| self.wl_output_name = wlo.name,
            .position => |pos| self.region.pos = .{ pos.x, pos.y },
            .dimensions => |dim| {
                std.debug.assert(dim.width > 0 and dim.height > 0);
                self.region.size = .{
                    // Here, we cast from i32 to u31, which should be safe as the documentation asserts
                    // that these are always positive.
                    @intCast(dim.width),
                    @intCast(dim.height),
                };
            },
        }
    }
};

pub const Window = struct {
    wm: *WindowManager,
    river: *river.WindowV1,
    node: *river.NodeV1,

    /// The TagSpace this window is in, or null if this window is in limbo (used if there are no
    /// outputs).
    tag_space: ?*TagSpace,
    mask: TagSpace.Mask,
    size: [2]u31,

    render: RenderState,

    /// A struct that stores data about the window the we decide and need to tell River about.
    /// Some fields of this are updated during a manage sequence, others during a render sequence
    pub const RenderState = struct {
        region: Region = .zero,
        hidden: bool = false,
        border_color: [4]u8 = @splat(0),
        set_fixed_props: bool = false,
        dirty: packed struct {
            pos: bool = false,
            size: bool = false,
            border_color: bool = false,
        } = .{},

        pub fn updateRegion(self: *RenderState, new: Region) void {
            std.debug.print("{} ~> {}\n", .{ self.region.size, new.size });
            if (@reduce(.Or, self.region.pos != new.pos)) self.dirty.pos = true;
            if (@reduce(.Or, self.region.size != new.size)) self.dirty.size = true;

            self.region = new;
        }
    };

    fn listener(_: *river.WindowV1, ev: river.WindowV1.Event, self: *Window) void {
        switch (ev) {
            .closed => {
                // TODO: find out where this window is even stored and remove it from there.
            },
            .dimensions_hint => |hint| {
                // take whatever size the stupid window wants to be, and throw that straight in the
                // garbage.
                _ = hint;
            },
            .dimensions => |dim| {
                std.debug.assert(dim.width > 0 and dim.height > 0);
                self.size = .{
                    @intCast(dim.width),
                    @intCast(dim.height),
                };
            },
            .app_id => {}, // TODO: appid-based rules or something?
            .title => {},
            .parent => {},
            .decoration_hint => {},
            .pointer_move_requested => {},
            .pointer_resize_requested => {},
            .show_window_menu_requested => {},
            .maximize_requested => {},
            .unmaximize_requested => {},
            .fullscreen_requested => {}, // TODO: fullscreen the window
            .exit_fullscreen_requested => {},
            .minimize_requested => {},
            .unreliable_pid => {},
            .presentation_hint => {},
            .identifier => {},
        }
    }
};

const WindowManager = @This();

/// Register listeners for window management.
pub fn setup(self: *WindowManager) void {
    self.globals.rwm.setListener(*WindowManager, rwmListener, self);
}

/// Initiate a shutdown
pub fn shutdown(self: *WindowManager) void {
    self.globals.rwm.stop();
}

pub fn deinit(self: *WindowManager) void {
    for (self.outputs.items) |outp| {
        outp.deinit();
    }
    self.outputs.deinit(self.globals.alloc);
}

pub fn selectedOutput(self: *WindowManager) ?*Output {
    if (self.selected_output >= self.outputs.items.len)
        // we either have no outputs, or someone messed up and forgot to update selected_output
        return null;
    return self.outputs.items[self.selected_output];
}

fn rwmListener(
    _: *river.WindowManagerV1,
    ev: river.WindowManagerV1.Event,
    self: *WindowManager,
) void {
    self.tryHandleEvent(ev) catch |e| {
        std.log.err("failure in window manager handler: {}", .{e});
        self.run_state = .errored;
    };
}

fn tryHandleEvent(self: *WindowManager, ev: river.WindowManagerV1.Event) !void {
    switch (ev) {
        .unavailable => {
            std.log.err("Window management unavailable.  Is another window manager running?", .{});
            self.run_state = .errored;
        },
        .finished => {
            std.log.info("Finished", .{});
            self.run_state = .graceful_shutdown;
        },
        .manage_start => try self.performManage(),
        .render_start => try self.performRender(),
        .session_locked => {},
        .session_unlocked => {},
        .window => |win| {
            const window = try self.globals.alloc.create(Window);
            errdefer self.globals.alloc.destroy(window);

            var tag_space: ?*TagSpace = null;
            if (self.selectedOutput()) |out| {
                tag_space = &out.tag_space;
                tag_space.?.windows_valid = false;
            }

            window.* = .{
                .wm = self,
                .river = win.id,
                .node = try win.id.getNode(),
                .tag_space = tag_space,
                .mask = if (tag_space) |ts| @as(TagSpace.Mask, 1) << ts.primary else 1,
                .size = @splat(0),
                .render = .{},
            };

            win.id.setListener(*Window, Window.listener, window);
            try self.windows.append(self.globals.alloc, window);
        },
        .output => |outp| {
            const output = try self.globals.alloc.create(Output);
            errdefer self.globals.alloc.destroy(output);

            output.* = .{
                .wm = self,
                .river = outp.id,
                .region = .zero,
                .wl_output_name = 0,
                .tag_space = .init(self),
            };

            outp.id.setListener(*Output, Output.listener, output);
            try self.outputs.append(self.globals.alloc, output);
        },
        .seat => {},
    }
}

fn performManage(self: *WindowManager) !void {
    defer self.globals.rwm.manageFinish();

    for (self.outputs.items) |outp| {
        const windows = try outp.tag_space.getWindows();
        try outp.tag_space.tagdata[outp.tag_space.primary].layout.performLayout(
            self,
            outp.region,
            windows,
        );

        for (windows) |winid| {
            const win = self.windows.items[winid];
            if (!win.render.set_fixed_props) {
                // TODO: this is a lazy hack
                win.river.setTiled(.{
                    .top = true,
                    .bottom = true,
                    .left = true,
                    .right = true,
                });

                win.river.useSsd();
                win.river.setCapabilities(.{
                    .fullscreen = true,
                });

                win.render.set_fixed_props = true;
            }

            if (win.render.dirty.size) {
                win.river.proposeDimensions(win.render.region.size[0], win.render.region.size[1]);
                win.river.setContentClipBox(0, 0, win.render.region.size[0], win.render.region.size[1]);
                win.river.setDimensionBounds(win.render.region.size[0], win.render.region.size[1]);
                win.render.dirty.size = false;
            }
        }
    }
}

fn performRender(self: *WindowManager) !void {
    defer self.globals.rwm.renderFinish();

    // hide/show windows
    for (self.windows.items) |win| {
        if (win.tag_space) |tagspace| {
            const should_hide = tagspace.mask & win.mask == 0;
            if (should_hide != win.render.hidden) {
                if (should_hide) win.river.hide() else win.river.show();
                win.render.hidden = should_hide;
            }
        } else if (!win.render.hidden) {
            win.river.hide();
            win.render.hidden = true;
        }
    }

    // update properties of windows in each tagspace
    for (self.outputs.items) |outp| {
        for (try outp.tag_space.getWindows()) |winid| {
            const win = self.windows.items[winid];

            if (win.render.dirty.pos) {
                win.node.setPosition(win.render.region.pos[0], win.render.region.pos[1]);
                win.render.dirty.pos = false;
            }
        }
    }
}
