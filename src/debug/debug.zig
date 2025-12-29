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

pub fn dbg_assert_eql(loc: std.builtin.SourceLocation, lhs: anytype, rhs: anytype) void {
    if (!std.meta.eql(lhs, rhs)) {
        dbg(loc, "[DEBUG FAILED ASSERT EQUAL]  lhs={any}  rhs={any}", .{ lhs, rhs });
        @panic("Failed assert");
    }
}

pub fn dbg_assert_eql_msg(loc: std.builtin.SourceLocation, lhs: anytype, rhs: anytype, comptime fmt: []const u8, args: anytype) void {
    if (!std.meta.eql(lhs, rhs)) {
        dbg(loc, "[DEBUG FAILED ASSERT EQUAL]  lhs={any}  rhs={any} " ++ "| info: " ++ fmt, .{ lhs, rhs } ++ args);
        @panic("Failed assert");
    }
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
