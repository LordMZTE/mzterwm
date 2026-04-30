const std = @import("std");
const wayland = @import("wayland");
const xkbcommon = @import("xkbcommon");

const Globals = @import("Globals.zig");
const WindowManager = @import("WindowManager.zig");

const river = wayland.client.river;

globals: *Globals,

entries: std.ArrayList(*KeyBind),
entry_pool: std.heap.MemoryPool(KeyBind),

seats: std.ArrayList(*WindowManager.Seat),

const KeyManager = @This();

pub const KeyBind = struct {
    bind: KeySpec,
    cb: Callback(*anyopaque),
    udata: *anyopaque,
    seatdata: std.ArrayList(struct {
        seat: *WindowManager.Seat,
        xkb_bind: *river.XkbBindingV1,
    }),

    /// This is saved here so we can immediately enable keybinds that should be active when a new
    /// seat appears.
    is_enabled: bool,

    pub fn enable(self: *KeyBind) void {
        if (self.is_enabled) return;
        for (self.seatdata.items) |seatdat| {
            seatdat.xkb_bind.enable();
        }
        self.is_enabled = true;
    }

    pub fn disable(self: *KeyBind) void {
        if (!self.is_enabled) return;

        for (self.seatdata.items) |seatdat| {
            seatdat.xkb_bind.disable();
        }
        self.is_enabled = false;
    }

    fn deinit(self: *KeyBind, alloc: std.mem.Allocator) void {
        for (self.seatdata.items) |it| {
            it.xkb_bind.destroy();
        }

        self.seatdata.deinit(alloc);
    }

    fn registerTo(self: *KeyBind, globals: *Globals, seat: *WindowManager.Seat) !void {
        const xkb_bind = try globals.xkb_binds.getXkbBinding(
            seat.river,
            @intFromEnum(self.bind.keysym),
            self.bind.mods,
        );
        xkb_bind.setListener(*anyopaque, self.cb, self.udata);
        if (self.is_enabled) xkb_bind.enable();
        try self.seatdata.append(globals.alloc, .{ .seat = seat, .xkb_bind = xkb_bind });
    }

    fn unregisterFrom(self: *KeyBind, seat: *WindowManager.Seat) void {
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

pub const KeySpec = struct {
    keysym: xkbcommon.Keysym,
    mods: river.SeatV1.Modifiers,
};

pub fn init(globals: *Globals) !KeyManager {
    return .{
        .globals = globals,
        .entries = .empty,
        .entry_pool = try .initCapacity(globals.alloc, 64),
        .seats = .empty,
    };
}

pub fn deinit(self: *KeyManager) void {
    for (self.entries.items) |it| {
        it.deinit(self.globals.alloc);
    }

    self.entries.deinit(self.globals.alloc);
    self.entry_pool.deinit(self.globals.alloc);

    for (self.seats.items) |seat| {
        seat.deinit();
    }
    self.seats.deinit(self.globals.alloc);
}

pub fn register(
    self: *KeyManager,
    comptime Udata: type,
    bind: KeySpec,
    cb: Callback(*Udata),
    udata: *Udata,
) !*KeyBind {
    const entry = try self.entry_pool.create(self.globals.alloc);
    errdefer self.entry_pool.destroy(entry);
    entry.* = .{
        .bind = bind,
        .cb = @ptrCast(cb),
        .udata = udata,
        .seatdata = .empty,
        .is_enabled = false,
    };

    try self.entries.append(self.globals.alloc, entry);

    for (self.seats.items) |seat| {
        try entry.registerTo(self.globals, seat);
    }

    return entry;
}

pub fn seatAdded(self: *KeyManager, new: *WindowManager.Seat) !void {
    for (self.entries.items) |ent| {
        try ent.registerTo(self.globals, new);
    }
    try self.seats.append(self.globals.alloc, new);
}

pub fn seatRemoved(self: *KeyManager, old: *WindowManager.Seat) void {
    for (self.entries.items) |ent| {
        ent.unregisterFrom(old);
    }

    for (self.seats.items, 0..) |it, i| {
        if (it == old) {
            _ = self.seats.swapRemove(i);
            break;
        }
    }
}

pub fn warpPointer(self: *KeyManager, to: @Vector(2, i32)) void {
    for (self.seats.items) |seat| {
        seat.warpPointer(to);
    }
}
