const std = @import("std");
const print = std.debug.print;

var printned_newline = false;

pub fn dbg_nl() void {
    print("\n", .{});
}

pub fn dbg(loc: std.builtin.SourceLocation, comptime fmt: []const u8, args: anytype) void {
    if (!printned_newline) dbg_nl();
    printned_newline = true;

    _ = .{ loc, fmt, args };
    print("[DEBUG | in '{s}' line: {d}] " ++ fmt ++ "\n", .{ loc.fn_name, loc.line } ++ args);
}

pub fn dbgx(
    loc: std.builtin.SourceLocation,
    comptime expression_str: []const u8,
    expression: anytype,
) @TypeOf(expression) {
    _ = .{ loc, expression, expression_str };
    dbg(loc, expression_str ++ "{any}", .{expression});
    return expression;
}
