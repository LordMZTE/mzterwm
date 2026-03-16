const std = @import("std");
const proto = @import("../proto.zig");

pub const Event = union(enum(u8)) {
    tag_switch_start,
    tag_switch_stop,
    tag_change: TagChange,
};

pub const TagChange = struct {
    /// The name of the output the tag change occured on
    output: []const u8,

    /// The new tag mask
    mask: proto.TagMask,

    /// The new primary tag
    primary: proto.TagIdx,
};
