const std = @import("std");

const token = @import("token.zig");
const Token: type = token.Token;
const CodePosition: type = token.CodePosition;

pub const ReportLocation = union(enum) {
    eof,
    no_location,
    pos: CodePosition,
};

pub const ErrorReporter = struct {
    const Self = @This();
    pub fn report_unexpected_eof(self: *Self, comptime expected_fmt: []const u8, expected_args: anytype) void {
        report_error(
            self,
            .{.eof},
            "Unexpected end of input. " ++ expected_fmt,
            expected_args,
        );
    }

    pub fn report_error(self: *Self, location: ReportLocation, comptime fmt: []const u8, args: anytype) void {
        // TODO: proper logging?
        _ = self;
        switch (location) {
            .eof => std.debug.print("[ERROR at the end of input] " ++ fmt ++ "\n", args),
            .no_location => std.debug.print("[ERROR] " ++ fmt ++ "\n", args),
            .pos => |pos| std.debug.print(
                "[ERROR at idx={d}] " ++ fmt ++ "\n",
                .{pos.start_idx} ++ args,
            ),
        }
    }
};
