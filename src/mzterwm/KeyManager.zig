const std = @import("std");
const wayland = @import("wayland");

const Globals = @import("Globals.zig");
const WindowManager = @import("WindowManager.zig");

const river = wayland.client.river;

globals: *Globals,

/// This is a SegmentedList because element pointers must stay valid.
entries: std.SegmentedList(KeyEntry, 64),

seats: std.ArrayList(*WindowManager.Seat),

const KeyManager = @This();

const KeyEntry = struct {
    bind: Keybind,
    cb: Callback(*anyopaque),
    udata: *anyopaque,
    seatdata: std.ArrayList(struct {
        seat: *WindowManager.Seat,
        xkb_bind: *river.XkbBindingV1,
    }),

    pub fn enable(self: *KeyEntry) void {
        for (self.seatdata.items) |seatdat| {
            seatdat.xkb_bind.enable();
        }
    }

    pub fn disable(self: *KeyEntry) void {
        for (self.seatdata.items) |seatdat| {
            seatdat.xkb_bind.disable();
        }
    }

    fn deinit(self: *KeyEntry, alloc: std.mem.Allocator) void {
        for (self.seatdata.items) |it| {
            it.xkb_bind.destroy();
        }

        self.seatdata.deinit(alloc);
    }

    fn registerTo(self: *KeyEntry, globals: *Globals, seat: *WindowManager.Seat) !void {
        const xkb_bind = try globals.xkb_binds.getXkbBinding(
            seat.river,
            self.bind.keysym,
            self.bind.mods,
        );
        try self.seatdata.append(globals.alloc, .{ .seat = seat, .xkb_bind = xkb_bind });
    }

    fn unregisterFrom(self: *KeyEntry, seat: *WindowManager.Seat) void {
        for (self.seatdata.items, 0..) |it, i| {
            if (it.seat == seat) {
                self.seatdata.swapRemove(i).xkb_bind.destroy();
                break;
            }
        }
    }
};

pub fn Callback(comptime T: type) type {
    return *const fn (
        keybind: *river.XkbBindingV1,
        ev: river.XkbBindingV1.Event,
        udata: T,
    ) void;
}

pub const Keybind = struct {
    keysym: u32,
    mods: river.SeatV1.Modifiers,
};

pub fn init(globals: *Globals) KeyManager {
    return .{
        .globals = globals,
        .entries = .{},
        .seats = .empty,
    };
}

pub fn deinit(self: *KeyManager) void {
    var iter = self.entries.iterator(0);
    while (iter.next()) |it| {
        it.deinit(self.globals.alloc);
    }

    self.entries.deinit(self.globals.alloc);
    self.seats.deinit(self.globals.alloc);
}

pub fn register(
    self: *KeyManager,
    comptime Udata: type,
    bind: Keybind,
    cb: Callback(*Udata),
    udata: *Udata,
) !*KeyEntry {
    const entry = try self.entries.addOne(self.globals.alloc);
    entry.* = .{
        .bind = bind,
        .cb = cb,
        .udata = udata,
        .seatdata = .empty,
    };

    for (self.seats.items) |seat| {
        try entry.registerTo(self.globals, seat);
    }

    return entry;
}

pub fn seatAdded(self: *KeyManager, new: *WindowManager.Seat) !void {
    var iter = self.entries.iterator(0);
    while (iter.next()) |ent| {
        try ent.registerTo(self.globals, new);
    }
    try self.seats.append(self.globals.alloc, new);
}

pub fn seatRemoved(self: *KeyManager, old: *WindowManager.Seat) void {
    var iter = self.entries.iterator(0);
    while (iter.next()) |ent| {
        ent.unregisterFrom(old);
    }

    for (self.seats.items, 0..) |it, i| {
        if (it == old) {
            _ = self.seats.swapRemove(i);
            break;
        }
    }
}
