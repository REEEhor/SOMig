const std = @import("std");
const assert = std.debug.assert;

pub fn SmallPtr(comptime Ptr: type) type {
    const is_maybe_optional_pointer = switch (@typeInfo(Ptr)) {
        .pointer => true,
        .optional => |optional_info| switch (@typeInfo(optional_info.child)) {
            .pointer => true,
            else => false,
        },
        else => false,
    };

    if (!is_maybe_optional_pointer) {
        @compileError(std.fmt.comptimePrint(
            "Expected `Ptr` to be a pointer type, or an optional pointer type, but it is `{s}`.",
            .{@typeName(Ptr)},
        ));
    }

    return packed struct {
        bits: u48,

        const Self = @This();

        pub fn pointee(self: Self) Ptr {
            return @ptrFromInt(@as(u64, self.bits));
        }

        pub fn new(full_ptr: Ptr) Self {
            const all_bits: u64 = @intFromPtr(full_ptr);
            assert(all_bits <= std.math.maxInt(u48));
            const truncated_bits: u48 = @truncate(all_bits);
            return .{ .bits = truncated_bits };
        }
    };
}
