const std = @import("std");

const defs = @import("custom_definitions/definitions.zig");
const int = defs.int;
const uint = defs.uint;

const dbg = std.debug.print;

pub fn main() !void {
    std.debug.print("This will be an amazing {s} project.\n\n", .{"SOMig"});
}

// test "simple test" {
//     const gpa = std.testing.allocator;
//     var list: std.ArrayList(i32) = .empty;
//     defer list.deinit(gpa); // Try commenting this out and see if zig detects the memory leak!
//     try list.append(gpa, 42);
//     try std.testing.expectEqual(@as(i32, 42), list.pop());
// }
