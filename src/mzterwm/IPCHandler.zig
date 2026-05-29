//! This file handles connections on the IPC socket.
//!
//! TODO: currently, all this uses blocking IO, which sucks because it may block the entire WM.
//! This will hopefully solve itself with Zig 0.16 async, so I decided not to bother with threads or
//! anything for now.
//!
//! Edit for the above TODO: it did not solve itself.
const std = @import("std");
const proto = @import("mzterwm-proto");

const posix = @import("posix.zig");

const WindowManager = @import("WindowManager.zig");

const IPCHandler = @This();

const log = std.log.scoped(.ipc);

srv: std.Io.net.Server,
clients: std.ArrayList(Connection),
wm: *WindowManager,

pub const Connection = struct {
    con: std.Io.net.Stream,
    reader: std.Io.net.Stream.Reader,
    writer: std.Io.net.Stream.Writer,

    const bufsize = 512;

    pub fn deinit(self: *const Connection, alloc: std.mem.Allocator, io: std.Io) void {
        // You may think that we also have to remove ourselves from the epoll fd here, but the
        // kernel actually does that for us when the fd is closed.
        self.con.close(io);

        // We have one heap-allocated buffer. The first half is for the reader, the latter for the
        // writer.
        std.debug.assert(self.writer.interface.buffer.ptr == self.reader.interface.buffer.ptr + bufsize);
        std.debug.assert(self.reader.interface.buffer.len == self.writer.interface.buffer.len);
        std.debug.assert(self.reader.interface.buffer.len == bufsize);

        alloc.destroy(@as(*[bufsize * 2]u8, self.reader.interface.buffer.ptr[0..(bufsize * 2)]));
    }
};

/// Initialize the handler on the given socket address.
/// Before starting the event loop, the caller must set the `wm` field.
pub fn initOn(io: std.Io, sockpath: []const u8) !IPCHandler {
    const addr: std.Io.net.UnixAddress = try .init(sockpath);
    return .{
        .srv = try addr.listen(io, .{}),
        .clients = .empty,
        .wm = undefined,
    };
}

pub fn deinit(self: *IPCHandler, alloc: std.mem.Allocator, io: std.Io) void {
    for (self.clients.items) |*client| {
        client.deinit(alloc, io);
    }
    self.clients.deinit(alloc);
    self.srv.deinit(io);
}

pub fn emitEventToAll(self: *IPCHandler, event: proto.pkt.Event) void {
    const alloc = self.wm.globals.alloc;
    const io = self.wm.globals.io;

    var i: usize = 0;

    while (i < self.clients.items.len) {
        const cl = &self.clients.items[i];
        proto.writePkt(&cl.writer.interface, event) catch |e| {
            log.warn("Couldn't dispatch event to client: {}, closing connection", .{e});
            cl.deinit(alloc, io);
            _ = self.clients.swapRemove(i);

            // Don't increment index here so we process the new client now at the current position.
            continue;
        };

        i += 1;
    }
}

pub fn flushAll(self: *IPCHandler) void {
    const alloc = self.wm.globals.alloc;
    const io = self.wm.globals.io;

    var i: usize = 0;

    while (i < self.clients.items.len) {
        const cl = &self.clients.items[i];
        cl.writer.interface.flush() catch |e| {
            log.warn("Couldn't flush client write buffer: {}, closing connection", .{e});
            cl.deinit(alloc, io);
            _ = self.clients.swapRemove(i);

            // Don't increment index here so we process the new client now at the current position.
            continue;
        };

        i += 1;
    }
}

/// Called from the event loop when any file descriptor that isn't otherwise used and is part of the
/// event loop becomes readable.
/// Returns true iff the event was handled.
pub fn onFdReadable(
    self: *IPCHandler,
    epfd: posix.EPoll,
    fd: std.posix.fd_t,
    events: u32,
) !bool {
    const alloc = self.wm.globals.alloc;
    const io = self.wm.globals.io;
    const EPOLL = std.os.linux.EPOLL;

    // Event on socket, new connection
    if (fd == self.srv.socket.handle) {
        if (events & (EPOLL.ERR | EPOLL.HUP) != 0) {
            log.err("Error condition on IPC socket fd", .{});
            return error.EndOfStream;
        }

        if (self.acceptNewClient()) |con| {
            try epfd.addFd(con.con.socket.handle, EPOLL.IN | EPOLL.ERR | EPOLL.HUP);
        } else |e| {
            std.log.err("Couldn't accept new client: {}", .{e});
        }

        return true;
    }

    // Event on a client, read and handle packet
    const client, const client_i = for (self.clients.items, 0..) |*client, i| {
        if (client.con.socket.handle == fd) break .{ client, i };
    } else return false;

    if (events & EPOLL.ERR != 0) {
        log.warn("Error condition on IPC socket peer, aborting connection", .{});
        client.deinit(alloc, io);
        _ = self.clients.swapRemove(client_i);
        return true;
    } else if (events & EPOLL.HUP != 0) {
        log.info("IPC client closed connection", .{});
        client.deinit(alloc, io);
        _ = self.clients.swapRemove(client_i);
        return true;
    }

    try client.reader.interface.fillMore();

    while (client.reader.interface.bufferedLen() != 0) {
        self.handleRequest(&client.reader.interface, &client.writer.interface) catch |e| {
            std.log.err("Couldn't handle client request: {}", .{e});
            client.deinit(alloc, io);
            _ = self.clients.swapRemove(client_i);
            break;
        };
        try client.writer.interface.flush();
    }

    return true;
}

fn acceptNewClient(self: *IPCHandler) !*Connection {
    const alloc = self.wm.globals.alloc;
    const io = self.wm.globals.io;

    const con = try self.acceptAndHandshake();
    {
        errdefer con.deinit(alloc, io);
        try self.clients.append(alloc, con);
    }
    errdefer self.clients.pop().?.deinit(alloc, io);

    const con_ptr = &self.clients.items[self.clients.items.len - 1];
    try self.sendInitialStateTo(con_ptr);

    return con_ptr;
}

fn acceptAndHandshake(self: *IPCHandler) !Connection {
    const alloc = self.wm.globals.alloc;
    const io = self.wm.globals.io;

    const con = try self.srv.accept(io);
    errdefer con.close(io);

    const buffers = try alloc.create([Connection.bufsize * 2]u8);
    errdefer alloc.destroy(buffers);

    var reader = con.reader(io, buffers[0..Connection.bufsize]);
    var writer = con.writer(io, buffers[Connection.bufsize..][0..Connection.bufsize]);

    try writer.interface.writeInt(proto.ProtocolVersion, proto.version, .little);
    try writer.interface.flush();
    const client_ver = try reader.interface.takeInt(proto.ProtocolVersion, .little);

    if (client_ver != proto.version) {
        log.warn("version mismatch, client is {} but we are {}", .{ client_ver, proto.version });
        return error.VersionMismatch;
    }

    log.info("client handshake successful", .{});

    return .{
        .con = con,
        .reader = reader,
        .writer = writer,
    };
}

fn sendInitialStateTo(self: *IPCHandler, con: *Connection) !void {
    for (self.wm.outputs.items) |outp| {
        const name = (outp.wl_output orelse continue).outp_name orelse continue;
        const ts = &(outp.tag_space orelse continue);

        try proto.writePkt(&con.writer.interface, proto.pkt.Event{ .tag_change = .{
            .output = name,
            .primary = ts.primary,
            .mask = ts.mask,
            .occupied = ts.computeOccupiedTags(),
        } });

        try proto.writePkt(&con.writer.interface, proto.pkt.Event{ .title_change = .{
            .output = name,
            .title = if (try ts.focusedWindow()) |win| win.title.items else "",
        } });
    }

    try con.writer.interface.flush();
}

fn handleRequest(
    self: *IPCHandler,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
) !void {
    var pkt = try proto.readPkt(reader, proto.pkt.Request, self.wm.globals.alloc);
    defer proto.freePkt(self.wm.globals.alloc, proto.pkt.Request, &pkt);

    switch (pkt) {
        .set_tags => |req| {
            if (req.mask == 0) {
                // TODO: reconsider this limitation.  This is mostly carried over from
                // River-classic, but why exactly shouldn't we have a zero mask?
                try proto.writePkt(writer, proto.pkt.Event{ .action_result = .{
                    .serial = req.serial,
                    .success = false,
                    .msg = "Attempt to set mask to 0",
                } });
                return;
            }

            if ((@as(proto.TagMask, 1) << req.primary) & req.mask == 0) {
                try proto.writePkt(writer, proto.pkt.Event{ .action_result = .{
                    .serial = req.serial,
                    .success = false,
                    .msg = "Attempt to set primary to a tag that isn't active",
                } });
                return;
            }

            const output = for (self.wm.outputs.items) |outp| {
                const name = (outp.wl_output orelse continue).outp_name orelse continue;
                if (std.mem.eql(u8, req.output, name)) break outp;
            } else {
                var res_buf: [128]u8 = undefined;
                try proto.writePkt(writer, proto.pkt.Event{ .action_result = .{
                    .serial = req.serial,
                    .success = false,
                    .msg = try std.fmt.bufPrint(&res_buf, "No output `{s}`", .{req.output}),
                } });
                return;
            };

            if (output.tag_space) |*ts| {
                ts.primary = req.primary;
                ts.mask = req.mask;
                self.wm.notifyTagsChangedOn(output);
                self.wm.updateActiveLayout();
                self.wm.requestManage();
                self.wm.ipc.flushAll();
            }

            try proto.writePkt(writer, proto.pkt.Event{ .action_result = .{
                .serial = req.serial,
                .success = true,
                .msg = "",
            } });
        },
    }
}
