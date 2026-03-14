//! The global window manager state.  This struct is self-referential, do not move it.

const std = @import("std");
const wayland = @import("wayland");
const xkbcommon = @import("xkbcommon");
const mzterwm = @import("../root.zig");

const action = @import("action.zig");

const Config = @import("Config.zig");
const Globals = @import("Globals.zig");
const KeyManager = @import("KeyManager.zig");
const TagSpace = @import("TagSpace.zig");

const river = wayland.client.river;

globals: *Globals,
config: Config,
run_state: enum {
    keep_running,
    errored,
    graceful_shutdown,
},
outputs: std.ArrayList(*Output),
windows: std.ArrayList(*Window),
keys: KeyManager,

/// Index into `outputs` for the currently selected output.  This always has to be in bounds.
selected_output: usize = 0,

/// A slice containing each workspace key.
tag_keys: []TagKeyData,

/// The number of tag keys the user is holding down at the moment.
tag_keys_down: u16,

global_user_keys: []UserKeyData,

pub const Output = struct {
    wm: *WindowManager,
    river: *river.OutputV1,
    region: mzterwm.Region,
    wl_output_name: u32,
    tag_space: TagSpace,

    pub fn deinit(self: *Output) void {
        self.river.destroy();
        self.tag_space.deinit();
        self.wm.globals.alloc.destroy(self);
    }

    fn listener(_: *river.OutputV1, ev: river.OutputV1.Event, self: *Output) void {
        switch (ev) {
            .removed => {
                for (self.wm.outputs.items, 0..) |other, i| {
                    if (other == self) {
                        const old = self.wm.outputs.orderedRemove(i);
                        defer old.deinit();

                        if (self.wm.selected_output > i) {
                            self.wm.selected_output -|= 1;
                        }

                        old.tag_space.evacuateTo(
                            // Move windows to other remaining outputs or limbo if there are no outputs
                            // left.
                            if (self.wm.selectedOutput()) |outp| &outp.tag_space else null,
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
        region: mzterwm.Region = .zero,
        hidden: bool = false,
        set_fixed_props: bool = false,
        border_width: u31 = 0,
        border_color: @Vector(4, u8) = @splat(0),
        dirty: packed struct {
            pos: bool = false,
            size: bool = false,
            border: bool = false,
        } = .{},

        /// Updates the region this whole window, including borders, should take up.
        pub fn updateRegion(self: *RenderState, new: mzterwm.Region) void {
            const inner = new.inset(self.border_width);

            if (@reduce(.Or, self.region.pos != inner.pos)) self.dirty.pos = true;
            if (@reduce(.Or, self.region.size != inner.size)) self.dirty.size = true;

            self.region = inner;
        }

        pub fn updateBorderColor(self: *RenderState, new: @Vector(4, u8)) void {
            if (self.border_width == 0) return;
            if (@reduce(.Or, self.border_color != new)) {
                self.dirty.border = true;
                self.border_color = new;
            }
        }
    };

    pub fn deinit(self: *Window) void {
        if (self.tag_space) |ts| {
            ts.windows_valid = false;
        }
        self.node.destroy();
        self.river.destroy();
        self.wm.globals.alloc.destroy(self);
    }

    pub fn focus(self: *Window) void {
        for (self.wm.keys.seats.items) |seat| {
            seat.river.focusWindow(self.river);
        }
    }

    fn listener(_: *river.WindowV1, ev: river.WindowV1.Event, self: *Window) void {
        switch (ev) {
            .closed => {
                for (self.wm.windows.items, 0..) |it, i| {
                    if (self == it) {
                        self.wm.windows.swapRemove(i).deinit();
                        break;
                    }
                }
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

pub const Seat = struct {
    wm: *WindowManager,
    river: *river.SeatV1,

    pub fn deinit(self: *Seat) void {
        self.river.destroy();
        self.wm.globals.alloc.destroy(self);
    }

    fn listener(_: *river.SeatV1, ev: river.SeatV1.Event, self: *Seat) void {
        switch (ev) {
            .removed => {
                self.wm.keys.seatRemoved(self);
            },
            .wl_seat => {},
            .pointer_enter => {},
            .pointer_leave => {},
            .window_interaction => |wint| {
                const rwin = wint.window orelse return;
                const win, const idx = for (self.wm.windows.items, 0..) |win, i| {
                    if (rwin == win.river) break .{ win, i };
                } else {
                    std.log.err(
                        "Got window interaction event for window taht isn't registered.",
                        .{},
                    );
                    return;
                };

                const space = win.tag_space orelse {
                    std.log.err("Got window interaction event for window that's in limbo.  " ++
                        "How'd you even get your pointer there?", .{});
                    return;
                };

                const id_in_space = for (space.windows.items, 0..) |winid, i| {
                    if (winid == idx) break i;
                } else
                    // This being reached would mean the window's tag_space field is set, but that
                    // space doesn't contain the window.  That's invalid state.
                    unreachable;

                space.selected_window = id_in_space;
                space.windows_valid = false;
                space.commitFocus() catch @panic("OOM");
            },
            .shell_surface_interaction => {},
            .op_delta => {},
            .op_release => {},
            .pointer_position => {},
        }
    }
};

const TagKeyData = struct {
    wm: *WindowManager,
};

const UserKeyData = struct {
    wm: *WindowManager,
    action: action.Action,
};

const WindowManager = @This();

pub fn init(globals: *Globals, config: Config) WindowManager {
    return .{
        .globals = globals,
        .config = config,
        .run_state = .keep_running,
        .outputs = .empty,
        .windows = .empty,
        .keys = .init(globals),
        .tag_keys = undefined, // initialized during setup
        .tag_keys_down = 0,
        .global_user_keys = undefined // initialized during setup
    };
}

/// Register listeners for window management.
pub fn setup(self: *WindowManager) !void {
    self.globals.rwm.setListener(*WindowManager, rwmListener, self);

    self.tag_keys = try self.globals.alloc.alloc(TagKeyData, self.config.tag_keys.keys.len);
    errdefer self.globals.alloc.free(self.tag_keys);

    for (self.tag_keys, self.config.tag_keys.keys) |*tkey, conf| {
        tkey.* = .{
            .wm = self,
        };

        const bind = try self.keys.register(TagKeyData, .{
            .keysym = conf.xkb,
            .mods = self.config.tag_keys.mods.toRiver(),
        }, onTagKeyEvent, tkey);
        bind.enable();
    }

    self.global_user_keys = try self.globals.alloc.alloc(UserKeyData, self.config.keybinds.len);
    errdefer self.globals.alloc.free(self.global_user_keys);

    for (self.global_user_keys, self.config.keybinds) |*ukey, conf| {
        ukey.* = .{
            .wm = self,
            .action = conf.action,
        };

        const bind = try self.keys.register(UserKeyData, .{
            .mods = conf.mods.toRiver(),
            .keysym = conf.key.xkb,
        }, onGlobalUserKeyEvent, ukey);
        bind.enable();
    }
}

fn onTagKeyEvent(_: *river.XkbBindingV1, ev: river.XkbBindingV1.Event, keydat: *TagKeyData) void {
    const tag: TagSpace.TagIdx = @intCast(keydat - keydat.wm.tag_keys.ptr);
    switch (ev) {
        .pressed => {
            keydat.wm.tag_keys_down +|= 1;
            const outp = keydat.wm.selectedOutput() orelse return;
            outp.tag_space.windows_valid = false;
            if (keydat.wm.tag_keys_down == 1) {
                // This is the first key being pressed this switch operation.  Set primary and focus
                // only tags we're now subsequently pressing.
                outp.tag_space.primary = tag;
                outp.tag_space.mask = @as(TagSpace.Mask, 1) << tag;
            } else {
                outp.tag_space.mask |= @as(TagSpace.Mask, 1) << tag;
            }

            std.log.debug("tags switched; primary: {}, mask: {b}", .{
                outp.tag_space.primary,
                outp.tag_space.mask,
            });
        },
        .released => {
            keydat.wm.tag_keys_down -|= 1;
        },
        .stop_repeat => {},
    }
}

fn onGlobalUserKeyEvent(
    _: *river.XkbBindingV1,
    ev: river.XkbBindingV1.Event,
    keydat: *UserKeyData,
) void {
    switch (ev) {
        .pressed => {
            keydat.action.perform(keydat.wm) catch |e| {
                std.log.err("Failed to perform global user keybind action: {}", .{e});
            };
        },
        .released => {},
        .stop_repeat => {},
    }
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

    for (self.windows.items) |win| {
        win.deinit();
    }
    self.windows.deinit(self.globals.alloc);
    self.keys.deinit();
    self.globals.alloc.free(self.tag_keys);
}

pub fn selectedOutput(self: *WindowManager) ?*Output {
    if (self.selected_output >= self.outputs.items.len)
        // we either have no outputs, or someone messed up and forgot to update selected_output
        return null;
    return self.outputs.items[self.selected_output];
}

/// Tell River to clear the focus.
pub fn unfocus(self: *WindowManager) void {
    for (self.keys.seats.items) |seat| {
        seat.river.clearFocus();
    }
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
                .render = .{
                    .border_width = self.config.borders.width,
                    .border_color = self.config.borders.focus_color.vec,
                    .dirty = .{ .border = self.config.borders.width != 0 },
                },
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
        .seat => |river_seat| {
            const seat = try self.globals.alloc.create(Seat);
            errdefer self.globals.alloc.destroy(seat);

            seat.* = .{
                .wm = self,
                .river = river_seat.id,
            };

            river_seat.id.setListener(*Seat, Seat.listener, seat);
            try self.keys.seatAdded(seat);
        },
    }
}

fn performManage(self: *WindowManager) !void {
    defer self.globals.rwm.manageFinish();

    for (self.outputs.items) |outp| {
        const windows = try outp.tag_space.getWindows();
        try outp.tag_space.tagdata[outp.tag_space.primary].layout.performLayout(
            self,
            outp.region.inset(self.config.gaps.output),
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

            const color = mzterwm.colorToRiver(win.render.border_color);

            if (win.render.dirty.border) {
                win.river.setBorders(
                    .{
                        .top = true,
                        .bottom = true,
                        .left = true,
                        .right = true,
                    },
                    win.render.border_width,
                    color[0],
                    color[1],
                    color[2],
                    color[3],
                );
                win.render.dirty.border = false;
            }
        }
    }
}
