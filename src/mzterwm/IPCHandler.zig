//! This file handles connections on the IPC socket.
//!
//! TODO: currently, all this uses blocking IO, which sucks because it may block the entire WM.
//! This will hopefully solve itself with Zig 0.16 async, so I decided not to bother with threads or
//! anything for now.
const std = @import("std");
const proto = @import("mzterwm-proto");

const WindowManager = @import("WindowManager.zig");

const IPCHandler = @This();

const log = std.log.scoped(.ipc);

srv: std.net.Server,
clients: std.ArrayList(Connection),
wm: *WindowManager,

pub const Connection = struct {
    con: std.net.Server.Connection,

    pub fn deinit(self: *const Connection) void {
        // You may think that we also have to remove ourselves from the epoll fd here, but the
        // kernel actually does that for us when the fd is closed.
        self.con.stream.close();
    }
};

/// Initialize the handler on the given socket address.
/// Before starting the event loop, the caller must set the `wm` field.
pub fn initOn(sockpath: []const u8) !IPCHandler {
    const addr = try std.net.Address.initUnix(sockpath);
    return .{
        .srv = try addr.listen(.{}),
        .clients = .empty,
        .wm = undefined,
    };
}

pub fn deinit(self: *IPCHandler, alloc: std.mem.Allocator) void {
    for (self.clients.items) |*client| {
        client.deinit();
    }
    self.clients.deinit(alloc);
    self.srv.deinit();
}

pub fn emitEventToAll(self: *IPCHandler, event: proto.pkt.Event) void {
    var write_buf: [512]u8 = undefined;
    var i: usize = 0;
    while (i < self.clients.items.len) {
        const cl = &self.clients.items[i];
        var writer = cl.con.stream.writer(&write_buf);
        writeAndFlushPacket(&writer.interface, event) catch |e| {
            log.warn("Couldn't dispatch event to client: {}, closing connection", .{e});
            cl.deinit();
            _ = self.clients.swapRemove(i);

            // Don't increment index here so we process the new client now at the current position.
            continue;
        };
        i += 1;
    }
}

fn writeAndFlushPacket(stream: *std.Io.Writer, pkt: anytype) !void {
    try proto.writePkt(stream, pkt);
    try stream.flush();
}

/// Called from the event loop when any file descriptor that isn't otherwise used and is part of the
/// event loop becomes readable.
/// Returns true iff the event was handled.
pub fn onFdReadable(
    self: *IPCHandler,
    alloc: std.mem.Allocator,
    epfd: std.posix.fd_t,
    fd: std.posix.fd_t,
    events: u32,
) !bool {
    const EPOLL = std.os.linux.EPOLL;

    // Event on socket, new connection
    if (fd == self.srv.stream.handle) {
        if (events & (EPOLL.ERR | EPOLL.HUP) != 0) {
            log.err("Error condition on IPC socket fd", .{});
            return error.EndOfStream;
        }

        if (acceptNewClient(self, alloc)) |con| {
            var add_ev: std.posix.system.epoll_event = .{
                .events = std.os.linux.EPOLL.IN,
                .data = .{ .fd = con.con.stream.handle },
            };

            try std.posix.epoll_ctl(epfd, std.os.linux.EPOLL.CTL_ADD, con.con.stream.handle, &add_ev);
        } else |e| {
            std.log.err("Couldn't accept new client: {}", .{e});
        }

        return true;
    }

    // Event on a client, read and handle packet
    const client, const client_i = for (self.clients.items, 0..) |*client, i| {
        if (client.con.stream.handle == fd) break .{ client, i };
    } else return false;

    if (events & EPOLL.ERR != 0) {
        log.warn("Error condition on IPC socket peer, aborting connection", .{});
        client.deinit();
        _ = self.clients.swapRemove(client_i);
        return true;
    } else if (events & EPOLL.HUP != 0) {
        log.info("IPC client closed connection", .{});
        client.deinit();
        _ = self.clients.swapRemove(client_i);
        return true;
    }

    var read_buf: [512]u8 = undefined;
    var reader = client.con.stream.reader(&read_buf);

    var write_buf: [512]u8 = undefined;
    var writer = client.con.stream.writer(&write_buf);

    try reader.interface().fillMore();

    handle_buflen: switch (reader.interface().bufferedLen()) {
        0 => {
            // buffer is empty, no more partially read packets
        },
        else => {
            self.handleRequest(reader.interface(), &writer.interface) catch |e| {
                std.log.err("Couldn't handle client request: {}", .{e});
                client.deinit();
                _ = self.clients.swapRemove(client_i);
            };
            try writer.interface.flush();
            continue :handle_buflen reader.interface().bufferedLen();
        },
    }

    return true;
}

fn acceptNewClient(self: *IPCHandler, alloc: std.mem.Allocator) !*Connection {
    const con = try self.acceptAndHandshake();
    {
        errdefer con.deinit();
        try self.clients.append(alloc, con);
    }
    errdefer self.clients.pop().?.deinit();

    const con_ptr = &self.clients.items[self.clients.items.len - 1];
    try self.sendInitialStateTo(con_ptr);

    return con_ptr;
}

fn acceptAndHandshake(self: *IPCHandler) !Connection {
    const con = try self.srv.accept();
    errdefer con.stream.close();

    // These use the same buffer because we only use the writer once and then reader once after.
    var buf: [@sizeOf(proto.ProtocolVersion)]u8 = undefined;
    var writer = con.stream.writer(&buf);
    var reader = con.stream.reader(&buf);

    try writer.interface.writeInt(proto.ProtocolVersion, proto.version, .little);
    try writer.interface.flush();
    const client_ver = try reader.interface().takeInt(proto.ProtocolVersion, .little);

    if (client_ver != proto.version) {
        log.warn("version mismatch, client is {} but we are {}", .{ client_ver, proto.version });
        return error.VersionMismatch;
    }

    log.info("client handshake successful", .{});

    return .{ .con = con };
}

fn sendInitialStateTo(self: *IPCHandler, con: *Connection) !void {
    var buf: [512]u8 = undefined;
    var writer = con.con.stream.writer(&buf);
    for (self.wm.outputs.items) |outp| {
        const name = (outp.wl_output orelse continue).outp_name orelse continue;
        const ts = &(outp.tag_space orelse continue);

        try proto.writePkt(&writer.interface, proto.pkt.Event{ .tag_change = .{
            .output = name,
            .primary = ts.primary,
            .mask = ts.mask,
        } });
    }

    try writer.interface.flush();
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
                try self.wm.notifyTagsChangedOn(output);
                self.wm.requestManage();
            }

            try proto.writePkt(writer, proto.pkt.Event{ .action_result = .{
                .serial = req.serial,
                .success = true,
                .msg = "",
            } });
        },
    }
}
