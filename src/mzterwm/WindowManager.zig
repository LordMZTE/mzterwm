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
const IPCHandler = @import("IPCHandler.zig");

const river = wayland.client.river;

globals: *Globals,
ipc: *IPCHandler,
config: Config,
run_state: enum {
    keep_running,
    errored,
    graceful_shutdown,
},
outputs: std.ArrayList(*Output),
windows: std.DoublyLinkedList,
window_pool: std.heap.MemoryPool(Window),
keys: KeyManager,

/// Index into `outputs` for the currently selected output.  This always has to be in bounds.
selected_output: usize = 0,

/// A slice containing each workspace key.
tag_keys: []TagKeyData,

/// The number of tag keys the user is holding down at the moment.
tag_keys_down: u16,

global_user_keys: []UserKeyData,

/// A map of output names to tag spaces.  If an output is removed, it's tag space is moved to this
/// map.  If it is later added again, we recover from here.
expunged_spaces: std.StringHashMapUnmanaged(TagSpace),

focus_override: enum {
    /// No layer surface has grabbed focus
    none,

    /// A layer surface has non-exclusive focus, we can regain it.
    exclusive,

    /// A layer surface has exclusive focus, we cannot change focus.
    non_exclusive,
},

pub const Output = struct {
    wm: *WindowManager,
    river: *river.OutputV1,
    layer: *river.LayerShellOutputV1,
    region: mzterwm.Region,
    non_exclusive_region: ?mzterwm.Region,

    /// This output's tag space.  This is optional because it will be null if this output doesn't
    /// have a corresponding wl_output known yet, in which case we don't know if we should create a
    /// new tag space or recover from the expunged ones if this is an output re-plug.
    tag_space: ?TagSpace,

    /// The corresponding wl_output, if that's known.
    /// There's a pointer in Globals.Output to this struct, too and those must be kept in sync.
    wl_output: ?*Globals.Output,

    pub fn deinit(self: *Output) void {
        self.river.destroy();
        self.layer.destroy();
        if (self.tag_space) |*ts| ts.deinit();
        if (self.wl_output) |wl| wl.wm_output = null;
        self.wm.globals.alloc.destroy(self);
    }

    /// This should be called after the `name` field has been set, which happens either when we get
    /// a `wl_output` event here for an output we already know the name of, or later when we get the
    /// name of that output in case we don't have it yet.
    pub fn onNameKnown(self: *Output) void {
        std.debug.assert(self.wl_output != null and self.wl_output.?.outp_name != null);
        std.debug.assert(self.tag_space == null);
        const name = self.wl_output.?.outp_name.?;

        if (self.wm.expunged_spaces.fetchRemove(name)) |kv| {
            std.log.info("recovered expunged tag space for {s}", .{name});
            self.tag_space = kv.value;
            self.wm.globals.alloc.free(kv.key);
        } else self.tag_space = .init(self.wm);

        // Now, we're able to tell the name of this output.  We can use this information to
        // find if any windows want to be on this new output.  If there are any, move them
        // over.
        var win_maybe_node = self.wm.windows.first;
        while (win_maybe_node) |node| : (win_maybe_node = node.next) {
            const win: *Window = .fromListNode(node);
            if (
            // window is in limbo, move it to this output
            win.tag_space == null or
                // window wants to be on this output
                (win.wanted_output != null and
                    std.mem.eql(u8, win.wanted_output.?, name)))
            {
                if (win.tag_space) |ts| ts.windows_valid = false;
                win.tag_space = &self.tag_space.?;
                self.tag_space.?.windows_valid = false;
            }
        }

        self.tag_space.?.commitFocus() catch @panic("OOM");
    }

    /// Returns the region of this output we can use to place windows.
    /// This takes into account any layer surfaces.
    pub fn layoutArea(self: *const Output) mzterwm.Region {
        return self.non_exclusive_region orelse self.region;
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

                        if (old.tag_space) |*ts| {
                            ts.evacuateTo(
                                // Move windows to other remaining outputs or limbo if there are no outputs
                                // left.
                                if (self.wm.selectedOutput()) |outp| if (outp.tag_space) |*ts_| ts_ else null else null,
                            ) catch @panic("OOM");
                            ts.windows_valid = false;

                            if (old.wl_output != null and old.wl_output.?.outp_name != null) {
                                const key = self.wm.globals.alloc.dupe(
                                    u8,
                                    old.wl_output.?.outp_name.?,
                                ) catch @panic("OOM");

                                self.wm.expunged_spaces.putNoClobber(
                                    self.wm.globals.alloc,
                                    key,
                                    ts.*,
                                ) catch @panic("OOM");
                                old.tag_space = null;

                                std.log.info("expunged space for {s}", .{key});
                            } else {
                                std.log.err("output removed before the name was known.  " ++
                                    "This means we got some very weird events from River.", .{});
                            }
                        }

                        break;
                    }
                }
            },
            .wl_output => |wlo| {
                var outp_maybe_node = self.wm.globals.outputs.first;
                while (outp_maybe_node) |node| : (outp_maybe_node = node.next) {
                    const outp: *Globals.Output = .fromListNode(node);
                    if (outp.name == wlo.name) {
                        self.wl_output = outp;
                        outp.wm_output = self;

                        if (outp.outp_name) |_| self.onNameKnown();
                        break;
                    }
                }
            },
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

    fn layerListener(
        _: *river.LayerShellOutputV1,
        ev: river.LayerShellOutputV1.Event,
        self: *Output,
    ) void {
        switch (ev) {
            .non_exclusive_area => |area| {
                self.non_exclusive_region = .{
                    .pos = .{ area.x, area.y },
                    .size = .{ @intCast(area.width), @intCast(area.height) },
                };
            },
        }
    }
};

pub const Window = struct {
    wm: *WindowManager,
    winlist_node: std.DoublyLinkedList.Node,
    river: *river.WindowV1,
    node: *river.NodeV1,

    /// The TagSpace this window is in, or null if this window is in limbo (used if there are no
    /// outputs).
    tag_space: ?*TagSpace,
    mask: TagSpace.Mask,
    size: [2]u31,

    /// If set, this window has an output it desires to be on which isn't necessarily the one it is
    /// currently on.
    /// This is set if the output a window is on is disconnected and it is thus evacuated to another
    /// tag space or limbo.  If an output of this name reappears, move it to that output.
    /// If the user manually moves the window to another output, this field is updated to reflect
    /// that.
    wanted_output: ?[]const u8,

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
        self.node.destroy();
        self.river.destroy();
        if (self.wanted_output) |name| self.wm.globals.alloc.free(name);
        self.wm.window_pool.destroy(self);
    }

    pub fn focus(self: *Window) void {
        for (self.wm.keys.seats.items) |seat| {
            seat.river.focusWindow(self.river);
        }
    }

    pub fn fromListNode(node: *std.DoublyLinkedList.Node) *Window {
        return @alignCast(@fieldParentPtr("winlist_node", node));
    }

    fn listener(_: *river.WindowV1, ev: river.WindowV1.Event, self: *Window) void {
        switch (ev) {
            .closed => {
                // Invalidate the tag space windows, and, if the removed window is before the
                // focused one, shift over the selection by one so it stays on the same window.
                if (self.tag_space) |ts| {
                    const ts_wins = ts.getWindows() catch @panic("OOM");
                    self.wm.windows.remove(&self.winlist_node);
                    ts.windows_valid = false;
                    const this_idx = std.mem.indexOfScalar(*Window, ts_wins, self) orelse unreachable;
                    if (ts_wins.len > 1 and ts.selected_window >= ts_wins.len - 1) {
                        ts.selected_window = ts_wins.len - 2;
                    } else if (ts.selected_window > this_idx) {
                        ts.selected_window -= 1;
                    }
                    ts.commitFocus() catch @panic("OOM");
                } else {
                    self.wm.windows.remove(&self.winlist_node);
                }

                self.deinit();
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
    layer: *river.LayerShellSeatV1,

    pub fn deinit(self: *Seat) void {
        self.river.destroy();
        self.layer.destroy();
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
                var maybe_node = self.wm.windows.first;
                const win = while (maybe_node) |node| : (maybe_node = node.next) {
                    const w: *Window = .fromListNode(node);
                    if (w.river == rwin) break w;
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

                const space_wins = space.getWindows() catch @panic("OOM");
                const id_in_space = std.mem.indexOfScalar(*Window, space_wins, win) orelse
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

    fn layerListener(
        _: *river.LayerShellSeatV1,
        ev: river.LayerShellSeatV1.Event,
        self: *Seat,
    ) void {
        self.wm.focus_override = switch (ev) {
            .focus_exclusive => .exclusive,
            .focus_non_exclusive => .non_exclusive,
            .focus_none => .none,
        };
        self.wm.onFocusOverrideChanged();
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

pub fn init(globals: *Globals, ipc: *IPCHandler, config: Config) WindowManager {
    return .{
        .globals = globals,
        .ipc = ipc,
        .config = config,
        .run_state = .keep_running,
        .outputs = .empty,
        .windows = .{},
        .window_pool = .init(globals.alloc),
        .keys = .init(globals),
        .tag_keys = undefined, // initialized during setup
        .tag_keys_down = 0,
        .global_user_keys = undefined, // initialized during setup
        .expunged_spaces = .empty,
        .focus_override = .none,
    };
}

/// Register listeners for window management.
pub fn setup(self: *WindowManager) !void {
    try self.window_pool.preheat(32);
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
            const ts = &(outp.tag_space orelse return);
            if (keydat.wm.tag_keys_down == 1) {
                // This is the first key being pressed this switch operation.  Set primary and focus
                // only tags we're now subsequently pressing.
                ts.primary = tag;
                ts.mask = @as(TagSpace.Mask, 1) << tag;

                // TODO: this is suboptimal because we send two events but flush each individually.
                // Perhaps consider persistent per-client buffers.
                keydat.wm.ipc.emitEventToAll(.tag_switch_start);
                try keydat.wm.notifyTagsChangedOn(outp);
            } else {
                ts.mask |= @as(TagSpace.Mask, 1) << tag;
                try keydat.wm.notifyTagsChangedOn(outp);
            }
        },
        .released => {
            keydat.wm.tag_keys_down -|= 1;
            if (keydat.wm.tag_keys_down == 0)
                keydat.wm.ipc.emitEventToAll(.tag_switch_stop);
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

    var win_node = self.windows.first;
    while (win_node) |node| {
        const win: *Window = .fromListNode(node);
        win_node = win.winlist_node.next;
        win.deinit();
    }
    self.window_pool.deinit();
    self.keys.deinit();

    // FIXME: this is invalid if setup hasn't been called
    self.globals.alloc.free(self.tag_keys);
    self.globals.alloc.free(self.global_user_keys);

    var exp_iter = self.expunged_spaces.iterator();
    while (exp_iter.next()) |ent| {
        self.globals.alloc.free(ent.key_ptr.*);
        ent.value_ptr.deinit();
    }
    self.expunged_spaces.deinit(self.globals.alloc);
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

/// Will invalide windows on the given output and notify IPC clients of a tag change event.
pub fn notifyTagsChangedOn(self: *WindowManager, outp: *Output) !void {
    const ts = &(outp.tag_space orelse return);
    ts.windows_valid = false;
    if (outp.wl_output) |wl|
        if (wl.outp_name) |name|
            self.ipc.emitEventToAll(.{ .tag_change = .{
                .mask = ts.mask,
                .primary = ts.primary,
                .output = name,
            } });

    std.log.debug(
        "tags switched; primary: {}, mask: {b}",
        .{ ts.primary, ts.mask },
    );
}

/// Request that River perform a manage sequence.  This is needed for, example, when a tag change
/// was caused by an IPC request.
pub fn requestManage(self: *WindowManager) void {
    self.globals.rwm.manageDirty();
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
            const window = try self.window_pool.create();
            errdefer self.window_pool.destroy(window);

            const sel_outp = self.selectedOutput();
            const tag_space = if (sel_outp) |out| if (out.tag_space) |*ts| ts else null else null;

            window.* = .{
                .winlist_node = .{},
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
                .wanted_output = outp: {
                    const sel = sel_outp orelse break :outp null;
                    const wl = sel.wl_output orelse break :outp null;
                    const name = wl.outp_name orelse break :outp null;
                    break :outp try self.globals.alloc.dupe(u8, name);
                },
            };

            std.log.info(
                "got new window that wants to be on output {s}",
                .{window.wanted_output orelse "<none>"},
            );

            win.id.setListener(*Window, Window.listener, window);
            self.windows.prepend(&window.winlist_node);

            if (tag_space) |ts| {
                // This is somewhat unintuitive.  Since we'll rebuild the space's window list and
                // the new window has just been prepended, this results in the new window being
                // focused.
                ts.selected_window = 0;
                ts.windows_valid = false;
                try ts.commitFocus();
            }
        },
        .output => |outp| {
            const output = try self.globals.alloc.create(Output);
            errdefer self.globals.alloc.destroy(output);

            output.* = .{
                .wm = self,
                .river = outp.id,
                .layer = try self.globals.layer_shell.getOutput(outp.id),
                .region = .zero,
                .non_exclusive_region = null,
                .tag_space = null,
                .wl_output = null,
            };

            outp.id.setListener(*Output, Output.listener, output);
            output.layer.setListener(*Output, Output.layerListener, output);
            try self.outputs.append(self.globals.alloc, output);
        },
        .seat => |river_seat| {
            const seat = try self.globals.alloc.create(Seat);
            errdefer self.globals.alloc.destroy(seat);

            seat.* = .{
                .wm = self,
                .river = river_seat.id,
                .layer = try self.globals.layer_shell.getSeat(river_seat.id),
            };

            river_seat.id.setListener(*Seat, Seat.listener, seat);
            seat.layer.setListener(*Seat, Seat.layerListener, seat);
            try self.keys.seatAdded(seat);

            // If there's an output selected and its tag space has a focused window, make this seat
            // focus it.
            if (self.selectedOutput()) |outp| {
                if (outp.tag_space) |*ts| {
                    const space_wins = try ts.getWindows();
                    if (ts.selected_window < space_wins.len) {
                        river_seat.id.focusWindow(space_wins[ts.selected_window].river);
                    }
                }
            }
        },
    }
}

fn performManage(self: *WindowManager) !void {
    defer self.globals.rwm.manageFinish();

    for (self.outputs.items) |outp| {
        const ts = &(outp.tag_space orelse continue);
        const windows = try ts.getWindows();
        try ts.tagdata[ts.primary].layout.performLayout(
            self,
            outp.layoutArea().inset(self.config.gaps.output),
            windows,
        );

        var maybe_node = self.windows.first;
        while (maybe_node) |node| : (maybe_node = node.next) {
            const win: *Window = .fromListNode(node);

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
    var maybe_node = self.windows.first;
    while (maybe_node) |node| : (maybe_node = node.next) {
        const win: *Window = .fromListNode(node);

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
        const ts = &(outp.tag_space orelse continue);
        for (try ts.getWindows()) |win| {
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

/// Called when the focus_override is updated
pub fn onFocusOverrideChanged(self: *WindowManager) void {
    // Invalidate the windows of all tag spaces so the decorations are updated accordingly
    for (self.outputs.items) |outp| {
        const ts = &(outp.tag_space orelse continue);
        ts.windows_valid = false;
    }
}
