const std = @import("std");
const s2s = @import("s2s");
const proto = @import("../proto.zig");

reader: std.net.Stream.Reader,
writer: std.net.Stream.Writer,

const Client = @This();

/// Connect to a remote socket.  Must perform handshake next.
pub fn connect(path: []const u8, read_buf: []u8, write_buf: []u8) !Client {
    const con = try std.net.connectUnixSocket(path);
    const reader = con.reader(read_buf);
    const writer = con.writer(write_buf);
    return .{ .reader = reader, .writer = writer };
}

/// Performs a handshake and returns the server's protocol version.
/// The caller should check if this equals proto.version and, if not, abort the connection.
pub fn handshake(self: *Client) !proto.ProtocolVersion {
    const srv_ver = try self.reader.interface().takeInt(proto.ProtocolVersion, .little);
    try self.writer.interface.writeInt(proto.ProtocolVersion, proto.version, .little);
    try self.writer.interface.flush();
    return srv_ver;
}

pub fn deinit(self: *const Client) void {
    self.reader.getStream().close();
}

/// Waits for an event from the server.  The caller must free the returned value with
/// `freePkt`.
pub fn waitEvent(self: *Client, alloc: std.mem.Allocator) !proto.pkt.Event {
    return proto.readPkt(self.reader.interface(), proto.pkt.Event, alloc);
}
