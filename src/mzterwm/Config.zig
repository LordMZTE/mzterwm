//! The configuration file.
//! See default_config.ziggy for documentation.

const std = @import("std");
const wayland = @import("wayland");
const xkbcommon = @import("xkbcommon");
const ziggy = @import("ziggy");

const layout = @import("layout.zig");
const action = @import("action.zig");

const TagSpace = @import("TagSpace.zig");

const river = wayland.client.river;

cursor: ?struct {
    theme: []const u8,
    size: u32,
} = null,

pointer_warp: enum {
    /// Never warp the pointer
    none,

    /// When the focused output changes, warp the pointer to the center of the output
    output,

    /// When the focused Window changes, warp the pointer to the center of the window.
    window,
} = .none,

tag_keys: struct {
    mods: Modifiers = .{ .meta = true },
    keys: []const Keysym = &.{
        .{ .xkb = xkbcommon.Keysym.@"1" },
        .{ .xkb = xkbcommon.Keysym.@"2" },
        .{ .xkb = xkbcommon.Keysym.@"3" },
        .{ .xkb = xkbcommon.Keysym.@"4" },
        .{ .xkb = xkbcommon.Keysym.@"5" },
        .{ .xkb = xkbcommon.Keysym.@"6" },
        .{ .xkb = xkbcommon.Keysym.@"7" },
        .{ .xkb = xkbcommon.Keysym.@"8" },
        .{ .xkb = xkbcommon.Keysym.@"9" },
    },
} = .{},

borders: struct {
    width: u31 = 4,
    base_color: Color = .{ .vec = .{ 0x80, 0x80, 0x80, 0x80 } },
    focus_color: Color = .{ .vec = .{ 0xff, 0x00, 0xff, 0xff } },
    fullscreen_color: Color = .{ .vec = .{ 0x00, 0x00, 0xff, 0xff } },
} = .{},

gaps: struct {
    window: u31 = 4,
    output: u31 = 4,
} = .{},

keybinds: []const struct {
    key: Keysym,
    mods: Modifiers,
    action: action.Action,
} = &.{},

layouts: struct {
    focus: layout.Focus.Config = .{},
    scroll: layout.Scroll.Config = .{},
} = .{},

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
        pub const deserialize = ziggyDeserialize;
    };

    fn ziggyDeserialize(
        d: *const ziggy.Deserializer,
        first_tok: ziggy.Tokenizer.Token,
        top_lvl: bool,
    ) ziggy.Deserializer.Error!Keysym {
        const str = try d.deserializeOne([:0]const u8, first_tok, top_lvl);

        var xkb_keysym: xkbcommon.Keysym = .fromName(str.ptr, .no_flags);

        if (xkb_keysym == .NoSymbol) {
            xkb_keysym = .fromName(str.ptr, .case_insensitive);

            if (xkb_keysym == .NoSymbol) {
                return d.unknownField(first_tok);
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
        pub const deserialize = ziggyDeserialize;
    };

    fn ziggyDeserialize(
        d: *const ziggy.Deserializer,
        first_tok: ziggy.Tokenizer.Token,
        top_lvl: bool,
    ) ziggy.Deserializer.Error!Color {
        const str = try d.deserializeOne([]const u8, first_tok, top_lvl);
        const n = std.fmt.parseInt(u32, str, 16) catch |e| switch (e) {
            error.Overflow => return d.overflow(first_tok),
            error.InvalidCharacter => return d.unexpected(first_tok),
        };

        return .{ .vec = .{
            @intCast(n >> 24),
            @intCast(n >> 16 & 0xff),
            @intCast(n >> 8 & 0xff),
            @intCast(n & 0xff),
        } };
    }
};

/// Find the path of the configuration file.  Returned path (if any) will be owned by the caller.
pub fn discover(alloc: std.mem.Allocator, env: *const std.process.Environ.Map) !?[]const u8 {
    if (env.get("XDG_CONFIG_HOME")) |conf_home| {
        return try std.fs.path.join(alloc, &.{
            conf_home,
            "mzterwm",
            "config.ziggy",
        });
    } else if (env.get("HOME")) |home| {
        return try std.fs.path.join(alloc, &.{
            home,
            ".config",
            "mzterwm",
            "config.ziggy",
        });
    }

    return null;
}

pub fn load(io: std.Io, alloc: std.mem.Allocator, arena: std.mem.Allocator, path: []const u8) !Config {
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |e| {
        std.log.err("attempting to open config file at `{s}`: {}", .{ path, e });
        return e;
    };
    defer file.close(io);

    var content_writer: std.Io.Writer.Allocating = .init(alloc);
    defer content_writer.deinit();

    // We use `readerStreaming` because `reader` is fundamentally broken.
    // *Someone* working on Zig std forgot that the size reported by `stat` is a heuristic and is
    // not to be relied upon at all.  `reader` however breaks when the reported size is incorrect,
    // which happens when people use superior config file generating systems (shameless plug:
    // Confgen), yet it is still somehow the default.
    var reader = file.readerStreaming(io, &.{});

    const content = try reader.interface.allocRemainingAlignedSentinel(alloc, .unlimited, .of(u8), 0);
    defer alloc.free(content);

    const opts: ziggy.Deserializer.Options = .{
        // Needed because we free the content of the file at the end of this function.
        .copy_strings = .always,
    };

    var meta: ziggy.Deserializer.Meta = .init;
    return ziggy.deserializeLeaky(Config, arena, content, &meta, opts) catch |e| {
        std.log.err(
            "Configuration parse error:\n{f}",
            .{meta.reportErrorsFmt(alloc, opts, content, path, e)},
        );
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
