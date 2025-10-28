const std = @import("std");

pub fn dbg(loc: std.builtin.SourceLocation, comptime fmt: []const u8, args: anytype) void {
    _ = .{ loc, fmt, args };
    std.debug.print("[DEBUG | in '{s}' line: {d}] " ++ fmt ++ "\n", .{ loc.fn_name, loc.line } ++ args);
}
