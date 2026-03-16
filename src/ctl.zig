const std = @import("std");
const args = @import("args");
const proto = @import("mzterwm-proto");

const Options = struct {
    pub const shorthands = .{
        .h = "help",
        .s = "socket",
    };

    pub const meta = .{
        .full_text = "CLI to interface with mzterwm",
        .option_docs = .{
            .help = "Show this help text and exit",
            .socket = "Path to the mzterwm socket.  Omit to auto-detect.",
        },
    };

    help: bool = false,
    socket: ?[]const u8 = null,
};

pub const Verb = union(enum) {
    listen: struct {},
};

pub fn main() !u8 {
    var gpa = if (@import("builtin").mode == .Debug) std.heap.DebugAllocator(.{}).init else {};
    const alloc = if (@TypeOf(gpa) == void) std.heap.c_allocator else gpa.allocator();
    defer if (@TypeOf(gpa) != void) {
        _ = gpa.deinit();
    };

    var stdio_buf: [512]u8 = undefined;
    const parse_res = args.parseWithVerbForCurrentProcess(
        Options,
        Verb,
        alloc,
        .print,
    ) catch |e| switch (e) {
        error.InvalidArguments => {
            // print help to stderr
            var writer = std.fs.File.stderr().writer(&stdio_buf);
            try printHelp(&writer.interface);
            try writer.interface.flush();
            return 1;
        },
        else => return e,
    };
    defer parse_res.deinit();

    var stdout = std.fs.File.stdout().writer(&stdio_buf);

    if (parse_res.options.help) {
        try printHelp(&stdout.interface);
        try stdout.interface.flush();
        return 0;
    }

    const verb = parse_res.verb orelse {
        // TODO: this is also hit if the user enters an unknown verb.  Probably a bug in zig-args.
        std.log.err("No verb was given.  See --help.", .{});
        return 1;
    };

    var read_buf: [512]u8 = undefined;
    var write_buf: [512]u8 = undefined;
    var client = if (parse_res.options.socket) |sock| try proto.Client.connect(
        sock,
        &read_buf,
        &write_buf,
    ) else con: {
        const path = try proto.findSocketPath(alloc);
        defer alloc.free(path);
        break :con try proto.Client.connect(path, &read_buf, &write_buf);
    };
    defer client.deinit();

    const srv_ver = try client.handshake();
    if (srv_ver != proto.version) {
        std.log.err(
            "Protocol version mismatch.  Server is on {}, we're on {}.",
            .{ srv_ver, proto.version },
        );
        return 1;
    }

    switch (verb) {
        .listen => while (true) {
            var ev = try client.waitEvent(alloc);
            defer proto.freePkt(alloc, proto.pkt.Event, &ev);

            try std.json.Stringify.value(ev, .{}, &stdout.interface);
            try stdout.interface.writeByte('\n');
            try stdout.interface.flush();
        },
    }

    return 0;
}

fn printHelp(to: *std.Io.Writer) !void {
    try args.printHelp(Options, "mzterwmctl", to);
    try to.writeAll(
        \\
        \\Verbs:
        \\  listen         Listen to incoming events and print them in JSON format.
        \\
    );
}
