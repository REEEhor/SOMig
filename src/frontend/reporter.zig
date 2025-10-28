const std = @import("std");
const Writer = std.io.Writer;

const token = @import("token.zig");
const Token: type = token.Token;
const CodePosition: type = token.CodePosition;

pub const ReportLocation = union(enum) {
    eof,
    no_location,
    pos: CodePosition,
};

// TODO: maybe methods `report_*` and `add_note` should return `Writer.Error!void` instead of just silently ignoring the error.
// But this makes them more difficult to be handled, since we call these methods when an error occured
// (which is more important than that the `ErrorReporter` failed to write the error).
pub const ErrorReporter = struct {
    const Self = @This();
    writer: *Writer,

    pub fn report_unexpected_eof(self: *Self, comptime expected_fmt: []const u8, expected_args: anytype) void {
        self.report_error(.eof, "Unexpected end of input. " ++ expected_fmt, expected_args);
    }

    pub fn report_error(self: *Self, location: ReportLocation, comptime fmt: []const u8, args: anytype) void {
        _ = switch (location) {
            .eof => self.writer.print("\n[ERROR at the end of input] " ++ fmt ++ "\n", args),
            .no_location => self.writer.print("\n[ERROR] " ++ fmt ++ "\n", args),
            .pos => |pos| self.writer.print(
                "\n[ERROR at {d}..{d}] " ++ fmt ++ "\n",
                .{ pos.start_idx, pos.end_idx_inclusive() } ++ args,
            ),
        } catch {};
    }

    pub fn add_note(self: *Self, location: ReportLocation, comptime fmt: []const u8, args: anytype) void {
        // Once the errors are structs (if they ever will be??), this will add some hint info on the last struct.
        _ = switch (location) {
            .eof => self.writer.print("[NOTE at the end of input] " ++ fmt ++ "\n", args),
            .no_location => self.writer.print("[NOTE] " ++ fmt ++ "\n", args),
            .pos => |pos| self.writer.print(
                "[NOTE at {d}..{d}] " ++ fmt ++ "\n",
                .{ pos.start_idx, pos.end_idx_inclusive() } ++ args,
            ),
        } catch {};
    }
};
