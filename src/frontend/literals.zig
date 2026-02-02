//!
//! Module for parsing literals (interger literal, string literals, ...)
//!

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

/// WARNING: Asserts that all characters are valid
pub fn parse_integer_literal(supposed_integer_literal: []const u8) ?i48 {
    return std.fmt.parseInt(i48, supposed_integer_literal, 10) catch |err| switch (err) {
        std.fmt.ParseIntError.Overflow => null,
        std.fmt.ParseIntError.InvalidCharacter => unreachable,
    };
}

/// WARNING: Asserts that all characters are valid
pub fn parse_float_literal(supposed_float_literal: []const u8) f64 {
    return std.fmt.parseFloat(f64, supposed_float_literal) catch |err| switch (err) {
        std.fmt.ParseFloatError.InvalidCharacter => unreachable,
    };
}

pub const ParseStringLiteralResult = union(enum) {
    ok: struct { parsed_owned_string: []const u8 },
    invalid_escape_sequence: struct { invalid_sequence: []const u8 },
    invalid_hex_code: struct { invalid_hex_code: []const u8 },
};
pub fn parse_string_literal(allocator: Allocator, supposed_string_literal: []const u8) Allocator.Error!ParseStringLiteralResult {
    // Do a double pass so we don't have to allocate more than nescessary
    assert(supposed_string_literal.len >= 2); // The bytes have to contain at least ''
    assert(supposed_string_literal[0] == '\'');
    assert(supposed_string_literal[supposed_string_literal.len - 1] == '\'');
    assert(supposed_string_literal[supposed_string_literal.len - 2] != '\\');

    const input: []const u8 = supposed_string_literal[1 .. supposed_string_literal.len - 1];
    var lenght: usize = 0; // The lenght of the output string
    {
        var idx: usize = 0;
        while (idx < input.len) : (lenght += 1) {
            assert(input[idx] != '\''); // We should never encounter non-escaped '
            idx += 1;
            if (input[idx - 1] != '\\') {
                continue;
            }

            // `idx` now points to an escaped character
            switch (translate_escaped_char(input[idx])) {
                .invalid => return .{ .invalid_escape_sequence = .{ .invalid_sequence = input[idx - 1 .. idx + 1] } },
                .single_byte => idx += 1,
                .expects_hex_code_after => {
                    idx += 1; // Skip the `x` or `X`
                    const remaining_chars = input[idx..];
                    if (remaining_chars.len > 2) {
                        return .{ .invalid_hex_code = .{ .invalid_hex_code = input[idx - 2 ..] } };
                    }
                    const is_hex = std.ascii.isHex;
                    if (!is_hex(remaining_chars[0]) or !is_hex(remaining_chars[1])) {
                        return .{ .invalid_hex_code = .{ .invalid_hex_code = input[idx - 2 .. idx + 2] } };
                    }
                    idx += 2;
                },
            } // switch
        } // while
    } // Figuring out length scope

    {
        const buffer = try allocator.alloc(u8, lenght);
        var writer = std.io.Writer.fixed(buffer);
        var idx: usize = 0;
        while (idx < input.len) {
            idx += 1;
            if (input[idx - 1] != '\\') {
                writer.writeByte(input[idx - 1]) catch unreachable;
                continue;
            }

            // `idx` now points to an escaped character
            const byte = sw: switch (translate_escaped_char(input[idx])) {
                .invalid => unreachable,
                .single_byte => |byte| {
                    idx += 1;
                    break :sw byte;
                },
                .expects_hex_code_after => {
                    idx += 1; // Skip the `x` or `X`
                    const first_digit = int_from_hex_digit(input[idx]);
                    const second_digit = int_from_hex_digit(input[idx + 1]);
                    idx += 2;
                    break :sw (first_digit * 16) + second_digit;
                },
            };
            writer.writeByte(byte) catch unreachable;
        }

        assert(buffer.len == writer.end);
        return .{ .ok = .{ .parsed_owned_string = buffer } };
    }
}

fn int_from_hex_digit(hex_digit_char: u8) u8 {
    return switch (hex_digit_char) {
        'A'...'Z' => |c| c - 'A',
        'a'...'z' => |c| c - 'a',
        '0'...'9' => |c| c - '0',
        else => unreachable,
    };
}

fn translate_escaped_char(char: u8) union(enum) {
    single_byte: u8,
    invalid,
    expects_hex_code_after,
} {
    return switch (char) {
        't' => .{ .single_byte = '\t' },
        'b' => .{ .single_byte = std.ascii.control_code.bel },
        'n' => .{ .single_byte = '\n' },
        'r' => .{ .single_byte = '\r' },
        'f' => .{ .single_byte = std.ascii.control_code.ff },
        0 => .{ .single_byte = 0 },
        '\'' => .{ .single_byte = '\'' },
        '\\' => .{ .single_byte = '\\' },
        'x', 'X' => .expects_hex_code_after,
        else => .invalid,
    };
}
