const std = @import("std");
const assert = std.debug.assert;
const Writer = std.io.Writer;

const token = @import("token.zig");
const Token: type = token.Token;
const CodePosition: type = token.CodePosition;

const colors = @import("../terminal.zig");
const RED: []const u8 = colors.RED;
const GREEN: []const u8 = colors.GREEN;
const YELLOW: []const u8 = colors.YELLOW;
const BOLD: []const u8 = colors.BOLD;
const RED_BG: []const u8 = colors.RED_BG;
const FAINT: []const u8 = colors.FAINT;
const ERR: []const u8 = colors.ERR;
const WARN: []const u8 = colors.WARN;
const RESET: []const u8 = colors.RESET;
const CYAN: []const u8 = colors.CYAN;
const NO_COLOR: []const u8 = "";

pub const ReportPosition = union(enum) {
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
    use_color: bool,
    source: []const u8,
    source_path: ?[]const u8,

    pub fn report_unexpected_eof(self: *Self, comptime expected_fmt: []const u8, expected_args: anytype) void {
        self.report_error(.eof, "Unexpected end of input. " ++ expected_fmt, expected_args);
    }

    pub fn report_error(self: *Self, position: ReportPosition, comptime fmt: []const u8, args: anytype) void {
        defer self.writer.flush() catch {};
        self.print("\n", .{});
        switch (position) {
            .eof => self.report_internal_eof("ERROR", fmt, args, RED),
            .no_location => {
                self.color_print("[ERROR] ", .{}, RED);
                self.print(fmt ++ "\n", args);
            },
            .pos => |pos| self.report_internal(pos, "ERROR", fmt, args, RED),
        }
    }

    pub fn report_warning(self: *Self, position: ReportPosition, comptime fmt: []const u8, args: anytype) void {
        defer self.writer.flush() catch {};
        self.print("\n", .{});
        switch (position) {
            .eof => self.report_internal_eof("WARN", fmt, args, YELLOW),
            .no_location => {
                self.color_print("[WARN] ", .{}, YELLOW);
                self.print(fmt ++ "\n", args);
            },
            .pos => |pos| self.report_internal(pos, "WARN", fmt, args, YELLOW),
        }
    }

    pub fn add_note(self: *Self, position: ReportPosition, comptime fmt: []const u8, args: anytype) void {
        defer self.writer.flush() catch {};

        // Once the errors are structs (if they ever will be??), this will add some hint info on the last struct.
        switch (position) {
            .eof => self.report_internal_eof("NOTE", fmt, args, CYAN),
            .no_location => {
                self.color_print("[NOTE] ", .{}, CYAN);
                self.print(fmt ++ "\n", args);
            },
            .pos => |pos| self.report_internal(pos, "NOTE", fmt, args, CYAN),
        }
    }

    fn report_internal_eof(
        self: *Self,
        report_name: []const u8,
        comptime message_fmt: []const u8,
        message_args: anytype,
        highlight_color: []const u8,
    ) void {
        const main_color = if (self.use_color) highlight_color else NO_COLOR;
        const faint_color = if (self.use_color) FAINT else NO_COLOR;
        const color_reset = if (self.use_color) RESET else NO_COLOR;

        const location = location_at_eof(self.source);

        self.print("{s}[{s} ", .{ main_color, report_name });
        if (self.source_path) |source_path| {
            self.print("in '{s}' ", .{source_path});
        } else {
            self.print("at ", .{});
        }
        self.print("line:{d} column:{d}\n{s}", .{ location.start_line_id + 1, location.column_id + 1, color_reset });
        self.print(message_fmt, message_args);

        const line_id_len = std.math.log10_int(location.end_line_id + 1) + 1;

        self.print("{s}", .{faint_color});
        for (0..line_id_len + 8) |_| self.print(" ", .{});
        self.print("|\n", .{});

        self.print("{s}", .{main_color});
        const last_line = self.source[location.first_line_start..];
        self.print("{s}\n", .{last_line});

        self.print("{s}", .{faint_color});
        for (0..line_id_len + 8) |_| self.print(" ", .{});
        self.print("|\n", .{});

        self.print("{s}", .{main_color});
        for (0..last_line.len) |_| self.print(" ", .{});
        self.print("^", .{});

        self.print("{s}", .{color_reset});
        self.print("\n", .{});
    }

    fn color_print(self: *Self, comptime fmt: []const u8, args: anytype, color: []const u8) void {
        const main_color: []const u8 = if (self.use_color) color else NO_COLOR;
        const color_reset: []const u8 = if (self.use_color) RESET else NO_COLOR;
        self.print("{s}" ++ fmt ++ "{s}", .{main_color} ++ args ++ .{color_reset});
    }

    fn report_internal(
        self: *Self,
        position: CodePosition,
        report_name: []const u8,
        comptime message_fmt: []const u8,
        message_args: anytype,
        highlight_color: []const u8,
    ) void {
        const main_color: []const u8 = if (self.use_color) highlight_color else NO_COLOR;
        const faint_color: []const u8 = if (self.use_color) RESET ++ FAINT else NO_COLOR;
        const color_reset: []const u8 = if (self.use_color) RESET else NO_COLOR;

        const location = location_from_position(position, self.source);

        // Print header (example):
        // ```
        // [REPORT in 'some_file.som' line:5 column: 7]
        // Some report message.
        // ```
        self.print("{s}[{s} ", .{ main_color, report_name });
        if (self.source_path) |source_path| {
            self.print("in '{s}' ", .{source_path});
        } else {
            self.print("at ", .{});
        }
        self.print("line:{d} column:{d}]\n{s}", .{ location.start_line_id + 1, location.column_id + 1, color_reset });
        self.print(message_fmt, message_args);
        self.write('\n');

        const line_id_len = std.math.log10_int(location.end_line_id + 1) + 1;

        self.print("{s}", .{faint_color});
        for (0..line_id_len + 8) |_| self.print(" ", .{});
        self.print("|\n", .{});

        //==================================
        // Print the first line of the error

        self.print(" line: ", .{});
        self.writer.printInt(location.start_line_id + 1, 10, .lower, .{ .width = line_id_len }) catch {};
        self.print(" |", .{});

        var idx = location.first_line_start;

        // Print text before the error
        self.print("{s}", .{color_reset});
        while (idx < position.start_idx) : (idx += 1) {
            const to_print = if (self.source[idx] == '\t') ' ' else self.source[idx];
            self.write(to_print);
        }
        // Print the error
        self.print("{s}", .{main_color});
        while (position.contains_byte_at(idx) and self.source[idx] != '\n' and self.source[idx] != '\r') : (idx += 1) {
            self.write(self.source[idx]);
        }
        var start_column_id = position.start_idx - location.first_line_start;
        var end_column_id = idx - location.first_line_start;

        if (location.is_multi_line()) {
            // Add dots at the end in case the error is multiline
            self.print("{s} ...", .{faint_color});
        } else {
            self.print("{s}", .{color_reset});
            while (idx < self.source.len and self.source[idx] != '\n' and self.source[idx] != '\r') : (idx += 1) {
                self.write(self.source[idx]);
            }
        }
        self.write('\n');
        self.print("{s}", .{color_reset});

        // Print the underline
        self.print("{s}", .{faint_color});
        for (0..line_id_len + 8) |_| self.write(' ');
        self.print("|", .{});
        //
        for (0..start_column_id) |_| self.write(' ');
        //
        self.print("{s}", .{main_color});
        for (start_column_id..end_column_id) |_| self.write('^');
        self.print("{s}", .{color_reset});
        self.write('\n');

        if (!location.is_multi_line()) {
            return; // Nothing more to print here
        }

        // ==================================
        // Print the second line of the error

        self.print("{s}", .{faint_color});
        self.print(" line: ", .{});
        self.writer.printInt(location.end_line_id + 1, 10, .lower, .{ .width = line_id_len }) catch {};
        self.print(" |", .{});

        self.print(" ... ", .{});
        idx = location.last_line_start;
        // Skip whitespace
        while (std.ascii.isWhitespace(self.source[idx])) : (idx += 1) {}
        start_column_id = location.last_line_start - idx;
        // Write the error part of the source code
        self.print("{s}", .{main_color});
        while (position.contains_byte_at(idx)) : (idx += 1) {
            self.write(self.source[idx]);
        }
        end_column_id = location.last_line_start - idx;
        // Write the rest of the line
        self.print("{s}", .{color_reset});
        while (position.contains_byte_at(idx)) : (idx += 1) {
            self.write(self.source[idx]);
        }
        self.write('\n');

        // Print the underline
        self.print("{s}", .{faint_color});
        for (0..line_id_len + 8) |_| self.write(' ');
        self.print("|", .{});
        //
        for (0..start_column_id) |_| self.write(' ');
        //
        self.print("{s}", .{main_color});
        for (start_column_id..end_column_id) |_| self.write('^');
        self.print("{s}", .{color_reset});
        self.write('\n');
    }

    fn print(self: *Self, comptime fmt: []const u8, args: anytype) void {
        self.writer.print(fmt, args) catch return;
    }

    fn write(self: *Self, byte: u8) void {
        self.writer.writeByte(byte) catch return;
    }
};

pub const CodeLocation = struct {
    first_line_start: usize,
    last_line_start: usize,

    column_id: usize,

    start_line_id: usize,
    end_line_id: usize,

    pub fn is_multi_line(self: @This()) bool {
        return self.start_line_id != self.end_line_id;
    }
};

//
// This function is not very effective, but it is fine, since the linear searches
// are made faster since `std.mem` uses SIMD most of the time.
//
// Also, we call this function only for errors, so at that point,
// the speed does not matter - the interpreter would exit anyway.
//
fn location_from_position(pos: CodePosition, source: []const u8) CodeLocation {
    assert(pos.end_idx_inclusive() < source.len);

    const start_line_id = count_scalar(u8, source[0..pos.start_idx], '\n');
    const end_line_id = count_scalar(u8, source[0..pos.end_idx_inclusive()], '\n');

    const find_first_line_start = std.mem.lastIndexOfScalar(u8, source[0..pos.start_idx], '\n');
    const first_line_start = if (find_first_line_start) |start| start + 1 else 0;

    const find_last_line_start = std.mem.lastIndexOfScalar(u8, source[0..pos.end_idx_inclusive()], '\n');
    const last_line_start = if (find_last_line_start) |start| start + 1 else 0;

    const column_id = pos.start_idx - first_line_start;

    return CodeLocation{
        .first_line_start = first_line_start,
        .last_line_start = last_line_start,
        .start_line_id = start_line_id,
        .end_line_id = end_line_id,
        .column_id = column_id,
    };
}

fn location_at_eof(source: []const u8) CodeLocation {
    const line_id = count_scalar(u8, source, '\n');

    const find_line_start = std.mem.lastIndexOfScalar(u8, source, '\n');
    const text_line_start = if (find_line_start) |start| start + 1 else 0;

    const column_id = source.len - text_line_start;

    return CodeLocation{
        .first_line_start = text_line_start,
        .last_line_start = text_line_start,
        .start_line_id = line_id,
        .end_line_id = line_id,
        .column_id = column_id,
    };
}

// Copied from `std.mem.count` but `needle` is a scalar
pub fn count_scalar(comptime T: type, haystack: []const T, needle: T) usize {
    var i: usize = 0;
    var found: usize = 0;

    while (std.mem.indexOfScalarPos(T, haystack, i, needle)) |idx| {
        i = idx + 1;
        found += 1;
    }

    return found;
}

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
///         const input = "some-test-code";
///         const debug = debug_reporter(input);
///         defer debug.deinit();
///         errdefer debug.dump_errors(); // gets called only when the test fails
///         ...
///         function_that_needs_a_reporter( debug.wrapped_reporter );
///     }
/// ```
pub fn debug_reporter(input: []const u8) DebugReporterWrapper {
    const buffer = std.testing.allocator.alloc(u8, 4096) catch @panic("Out of memory for debug allocator");
    const writer: *std.io.Writer = std.testing.allocator.create(std.io.Writer) catch @panic("Out of memory for debug allocator");
    writer.* = std.io.Writer.fixed(buffer);
    const reporter = ErrorReporter{
        .writer = writer,
        .source = input,
        .source_path = null,
        .use_color = true,
    };
    return DebugReporterWrapper{
        .wrapped_reporter = reporter,
    };
}
