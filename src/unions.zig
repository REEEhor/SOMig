const std = @import("std");

pub fn get_payload(
    tagged_union: anytype,
    comptime tag: std.meta.Tag(@TypeOf(tagged_union)),
) ?@FieldType(@TypeOf(tagged_union), @tagName(tag)) {
    switch (tagged_union) {
        tag => |payload| return payload,
        else => return null,
    }
}
