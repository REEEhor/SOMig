const std = @import("std");

const token = @import("token.zig");
const Token: type = token.Token;
const CodePosition: type = token.CodePosition;

const ReportLocation = union(enum) {
    eof,
    no_location,
    pos: CodePosition,
};

const ErrorReporter = struct {
    const Self = @This();
    fn report_unexpected_eof(self: *Self, comptime expected_fmt: []const u8, expected_args: anytype) void {
        report_error(
            self,
            .{.eof},
            "Unexpected end of input. " ++ expected_fmt,
            expected_args,
        );
    }

    fn report_error(self: *Self, location: ReportLocation, comptime fmt: []const u8, args: anytype) void {
        // TODO: proper logging?
        _ = self;
        switch (location) {
            .eof => std.debug.print("[ERROR at the end of input] " ++ fmt ++ "\n", args),
            .no_location => std.debug.print("[ERROR] " ++ fmt ++ "\n", args),
            .pos => |code_span| std.debug.print(
                "[ERROR at line {d} column {d}] " ++ fmt ++ "\n",
                args ++ .{ code_span.start.line, code_span.start.column },
            ),
        }
    }
};
