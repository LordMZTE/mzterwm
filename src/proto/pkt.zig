const std = @import("std");
const proto = @import("../proto.zig");

pub const Serial = u32;

pub const Request = union(enum) {
    /// Set the tags on a given output.  Server will respond with an action_result using the given
    /// serial.
    set_tags: struct {
        /// Output to set tags on
        output: []const u8,

        /// New tag mask.  It is a protocol violation for this to be zero.
        mask: proto.TagMask,

        /// Index of the primary tag.  Must be in bounds.
        primary: proto.TagIdx,

        /// Serial for the response.
        serial: Serial,
    },
};

pub const Event = union(enum) {
    /// The user has started an interactive tag switch
    tag_switch_start,

    /// The user has stopped an interactive tag switch
    tag_switch_stop,

    /// Tags have been changed
    tag_change: TagChange,

    /// A response to certain requests.  See request documentation for details.
    action_result: struct {
        serial: Serial,
        success: bool,
        msg: []const u8,
    },
};

pub const TagChange = struct {
    /// The name of the output the tag change occured on
    output: []const u8,

    /// The new tag mask
    mask: proto.TagMask,

    /// The new primary tag
    primary: proto.TagIdx,
};
