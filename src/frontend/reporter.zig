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

pub const DebugReporterWrapper = struct {
    const Self = @This();
    wrapped_reporter: ErrorReporter,

    pub fn deinit(self: *const Self) void {
        std.testing.allocator.free(self.wrapped_reporter.writer.buffer);
        std.testing.allocator.destroy(self.wrapped_reporter.writer);
    }

    pub fn dump_errors(self: *const Self) void {
        const buffer = self.wrapped_reporter.writer.buffer;
        const end_idx = self.wrapped_reporter.writer.end;
        const errors_text = buffer[0..end_idx];
        if (errors_text.len != 0) {
            std.debug.print("\n[DEBUG-ERROR-REPORTER] Reported error text:\n{s}\n", .{errors_text});
        } else {
            std.debug.print("\n[DEBUG-ERROR-REPORTER] No error text.\n", .{});
        }
    }
};

/// Returns a wrapper around `ErrorReporter` which prints the errors captured by `ErrorReporter` via `std.debug.print`
/// only when the test returns an error (via calling `.dump_errors()` method in `errdefer`).
///
/// Usage:
/// ```zig
///     test "some test" {
///         const debug = debug_reporter();
///         defer debug.deinit();
///         errdefer debug.dump_errors(); // gets called only when the test fails
///         ...
///         function_that_needs_a_reporter( debug.wrapped_reporter );
///     }
/// ```
pub fn debug_reporter() DebugReporterWrapper {
    const buffer = std.testing.allocator.alloc(u8, 4096) catch @panic("Out of memory for debug allocator");
    const writer: *std.io.Writer = std.testing.allocator.create(std.io.Writer) catch @panic("Out of memory for debug allocator");
    writer.* = std.io.Writer.fixed(buffer);
    const reporter = ErrorReporter{ .writer = writer };
    return DebugReporterWrapper{
        .wrapped_reporter = reporter,
    };
}
