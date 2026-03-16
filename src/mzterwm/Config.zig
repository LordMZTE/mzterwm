//! The configuration file.
//! See default_config.ziggy for documentation.

const std = @import("std");
const wayland = @import("wayland");
const xkbcommon = @import("xkbcommon");
const ziggy = @import("ziggy");

const action = @import("action.zig");

const TagSpace = @import("TagSpace.zig");

const river = wayland.client.river;

tag_keys: struct {
    mods: Modifiers = .{ .meta = true },
    keys: []const Keysym = &.{
        .{ .xkb = @enumFromInt(xkbcommon.Keysym.@"1") },
        .{ .xkb = @enumFromInt(xkbcommon.Keysym.@"2") },
        .{ .xkb = @enumFromInt(xkbcommon.Keysym.@"3") },
        .{ .xkb = @enumFromInt(xkbcommon.Keysym.@"4") },
        .{ .xkb = @enumFromInt(xkbcommon.Keysym.@"5") },
        .{ .xkb = @enumFromInt(xkbcommon.Keysym.@"6") },
        .{ .xkb = @enumFromInt(xkbcommon.Keysym.@"7") },
        .{ .xkb = @enumFromInt(xkbcommon.Keysym.@"8") },
        .{ .xkb = @enumFromInt(xkbcommon.Keysym.@"9") },
    },
} = .{},

borders: struct {
    width: u31 = 4,
    base_color: Color = .{ .vec = .{ 0x80, 0x80, 0x80, 0x80 } },
    focus_color: Color = .{ .vec = .{ 0xff, 0x00, 0xff, 0xff } },
} = .{},

gaps: struct {
    window: u31 = 4,
    output: u31 = 4,
} = .{},

keybinds: []const struct {
    key: Keysym,
    mods: Modifiers,
    action: action.Action,
},

const Config = @This();

pub const Modifiers = packed struct {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    mod3: bool = false,
    meta: bool = false,
    mod5: bool = false,

    pub fn toRiver(self: Modifiers) river.SeatV1.Modifiers {
        return .{
            .shift = self.shift,
            .ctrl = self.ctrl,
            .mod1 = self.alt,
            .mod3 = self.mod3,
            .mod4 = self.meta,
            .mod5 = self.mod5,
        };
    }
};

pub const Keysym = struct {
    xkb: xkbcommon.Keysym,

    pub const ziggy_options = struct {
        pub const parse = ziggyParse;
    };

    fn ziggyParse(
        parser: *ziggy.Parser,
        first_tok: ziggy.Tokenizer.Token,
    ) ziggy.Parser.Error!Keysym {
        var keysym_buf: [512]u8 = undefined;
        const str_no_sentinel = try parser.parseBytes([]const u8, first_tok);

        if (str_no_sentinel.len >= keysym_buf.len) {
            // Probably not the best information because this has no source location information,
            // but if someone passes a 512 character long key name, it's really their own fault.
            return parser.addError(.overflow);
        }

        @memcpy(keysym_buf[0..str_no_sentinel.len], str_no_sentinel);
        keysym_buf[str_no_sentinel.len] = 0;
        const str: [:0]u8 = @ptrCast(keysym_buf[0..str_no_sentinel.len]);

        var xkb_keysym: xkbcommon.Keysym = .fromName(str.ptr, .no_flags);

        if (xkb_keysym == .NoSymbol) {
            xkb_keysym = .fromName(str.ptr, .case_insensitive);

            if (xkb_keysym == .NoSymbol) {
                return parser.addError(.{
                    .unknown_field = .{
                        .name = first_tok.loc.src(parser.code),
                        .sel = first_tok.loc.getSelection(parser.code),
                    },
                });
            }

            var buf: [128]u8 = undefined;
            const sym_name = buf[0..@intCast(xkb_keysym.getName(&buf, buf.len))];

            std.log.warn(
                "Config specified keysym `{s}` with incorrect capitalization, should be `{s}`",
                .{ str.ptr, sym_name },
            );
        }

        return .{ .xkb = xkb_keysym };
    }
};

pub const Color = struct {
    vec: @Vector(4, u8),
    pub const ziggy_options = struct {
        pub const parse = ziggyParse;
    };

    fn ziggyParse(
        parser: *ziggy.Parser,
        first_tok: ziggy.Tokenizer.Token,
    ) ziggy.Parser.Error!Color {
        const str = try parser.parseBytes([]const u8, first_tok);
        const n = std.fmt.parseInt(u32, str, 0x10) catch {
            return parser.addError(.overflow);
        };

        return .{ .vec = .{
            @intCast(n >> 24),
            @intCast(n >> 16 & 0xff),
            @intCast(n >> 8 & 0xff),
            @intCast(n & 0xff),
        } };
    }
};

pub fn load(alloc: std.mem.Allocator, arena: std.mem.Allocator, maybe_path: ?[]const u8) !Config {
    const filepath = path: {
        if (maybe_path) |path| {
            break :path try alloc.dupe(u8, path);
        } else if (std.posix.getenv("XDG_CONFIG_HOME")) |conf_home| {
            break :path try std.fs.path.join(alloc, &.{
                conf_home,
                "mzterwm",
                "config.ziggy",
            });
        } else if (std.posix.getenv("HOME")) |home| {
            break :path try std.fs.path.join(alloc, &.{
                home,
                ".config",
                "mzterwm",
                "config.ziggy",
            });
        }

        std.log.err(
            "could not determine path for config file because neither" ++
                "MZTERWM_CONFIG nor XDG_CONFIG_HOME nor HOME were set!",
            .{},
        );
        return error.MissingEnv;
    };
    defer alloc.free(filepath);

    var file = std.fs.cwd().openFile(filepath, .{}) catch |e| {
        std.log.err("attempting to open config file at `{s}`: {}", .{ filepath, e });
        return error.CouldNotOpenConfig;
    };
    defer file.close();

    var content_writer: std.Io.Writer.Allocating = .init(alloc);
    defer content_writer.deinit();

    // We use `readerStreaming` because `reader` is fundamentally broken.
    // *Someone* working on Zig std forgot that the size reported by `stat` is a heuristic and is
    // not to be relied upon at all.  `reader` however breaks when the reported size is incorrect,
    // which happens when people use superior config file generating systems (shameless plug:
    // Confgen), yet it is still somehow the default.
    var reader = file.readerStreaming(&.{});
    _ = try reader.interface.streamRemaining(&content_writer.writer);

    // add sentinel
    try content_writer.writer.writeByte(0);
    const content_with_sentinel = content_writer.written();
    const content: [:0]u8 = @ptrCast(content_with_sentinel[0 .. content_with_sentinel.len - 1]);

    var diag: ziggy.Diagnostic = .{ .path = filepath };

    return ziggy.parseLeaky(Config, arena, content, .{ .diagnostic = &diag }) catch |e| {
        std.log.err("Configuration parse error:\n{f}", .{diag.fmt(content)});
        return e;
    };
}

pub fn validate(self: *const Config) error{ConfigInvalid}!void {
    if (self.tag_keys.keys.len > TagSpace.bitwidth) {
        std.log.err("tag_keys.keys specifies {} keys but there are only {} tags!", .{
            self.tag_keys.keys.len,
            TagSpace.bitwidth,
        });
        return error.ConfigInvalid;
    }
}
