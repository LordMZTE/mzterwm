//! This file handles connections on the IPC socket.
//!
//! TODO: currently, all this uses blocking IO, which sucks because it may block the entire WM.
//! This will hopefully solve itself with Zig 0.16 async, so I decided not to bother with threads or
//! anything for now.
const std = @import("std");
const proto = @import("mzterwm-proto");

const IPCHandler = @This();

const log = std.log.scoped(.ipc);

srv: std.net.Server,
clients: std.ArrayList(Connection),

pub const Connection = struct {
    con: std.net.Server.Connection,

    pub fn deinit(self: *const Connection) void {
        // You may think that we also have to remove ourselves from the epoll fd here, but the
        // kernel actually does that for us when the fd is closed.
        self.con.stream.close();
    }
};

pub fn initOn(sockpath: []const u8) !IPCHandler {
    const addr = try std.net.Address.initUnix(sockpath);
    return .{
        .srv = try addr.listen(.{}),
        .clients = .empty,
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

        const con = self.acceptAndHandshake() catch |e| {
            log.warn("Connection initialization failure: {}", .{e});
            return true;
        };
        {
            errdefer con.deinit();
            try self.clients.append(alloc, con);
        }
        errdefer self.clients.pop().?.deinit();

        var add_ev: std.posix.system.epoll_event = .{
            .events = std.os.linux.EPOLL.IN,
            .data = .{ .fd = con.con.stream.handle },
        };
        try std.posix.epoll_ctl(epfd, std.os.linux.EPOLL.CTL_ADD, con.con.stream.handle, &add_ev);

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

    // TODO: handle packet

    return true;
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
