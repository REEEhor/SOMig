/// @baka-src Heavily inspired by the `tokenizer.zig` in the standard library.
const std = @import("std");
const error_reporter = @import("reporter.zig");
const ErrorReporter: type = error_reporter.ErrorReporter;

pub const token = @import("token.zig");
const Token: type = token.Token;
const TokenKind: type = token.TokenKind;
const CodePosition: type = token.CodePosition;
const IntegerRepr: type = token.IntegerRepresentation;
const FloatRepr: type = token.FloatRepresentation;

pub const LexerError = error{
    unexpected_character,
    alone_colon,
    non_ascii_byte,
    number_literal_too_big,
};

pub const Lexer = struct {
    const Self = @This();
    current_char_idx: usize,
    text: []const u8,
    buffer_peeked_token: ?Token,
    reporter: ErrorReporter,

    pub fn create(input: []const u8, reporter: ErrorReporter) Self {
        return Lexer{
            .current_char_idx = 0,
            .text = input,
            .buffer_peeked_token = null,
            .reporter = reporter,
        };
    }

    /// Returning `null` means eof.
    pub fn peek_token(self: *Self) LexerError!?Token {
        if (self.buffer_peeked_token) |t| {
            return t;
        }
        self.buffer_peeked_token = null;
        self.buffer_peeked_token = try self.next_token();
        return self.buffer_peeked_token;
    }

    /// Returning `null` means eof.
    pub fn next_token(self: *Self) LexerError!?Token {
        if (self.buffer_peeked_token) |t| {
            self.buffer_peeked_token = null;
            return t;
        }
        try self.skip_whitespace();

        const token_start_idx = self.current_char_idx;
        const peeked_char: u8 = try self.current_char() orelse return null;

        switch (peeked_char) {
            ':' => {
                self.current_char_idx += 1;
                switch (try self.current_char() orelse 0) {
                    '=' => {
                        self.current_char_idx += 1;
                        return Token{ .pos = CodePosition.at(token_start_idx), .kind = .assign };
                    },
                    'a'...'z', 'A'...'Z', '_' => {
                        const token_end_idx = try self.lex_identifier(false);
                        const identifier = self.text[token_start_idx..token_end_idx];
                        return Token{
                            .pos = CodePosition.from_start_and_end(token_start_idx, token_end_idx - 1),
                            .kind = .{ .block_param = identifier },
                        };
                    },
                    else => {
                        self.reporter.report_error(
                            .{ .pos = CodePosition.at(token_start_idx) },
                            "Found the ':' character on its own. Maybe it should be at the end of some `keywordMessage:` or at the beginning of some `:blockParameter`?",
                            .{},
                        );
                        return LexerError.alone_colon;
                    },
                }
            },
            'a'...'z', 'A'...'Z', '_' => {
                const token_end_idx = try self.lex_identifier(true);
                const identifier = self.text[token_start_idx..token_end_idx];

                var kind: TokenKind = undefined;
                if (identifier[identifier.len - 1] == ':') {
                    kind = .{ .keyword_message = identifier };
                } else {
                    kind = .{ .identifier = identifier };
                }
                return Token{
                    .pos = CodePosition.from_start_and_end(token_start_idx, token_end_idx - 1),
                    .kind = kind,
                };
            },
            '^' => {
                self.current_char_idx += 1;
                return Token{ .pos = CodePosition.at(token_start_idx), .kind = .exit };
            },
            '.' => {
                self.current_char_idx += 1;
                return Token{ .pos = CodePosition.at(token_start_idx), .kind = .dot };
            },
            '(' => {
                self.current_char_idx += 1;
                return Token{ .pos = CodePosition.at(token_start_idx), .kind = .open_parenthesis };
            },
            ')' => {
                self.current_char_idx += 1;
                return Token{ .pos = CodePosition.at(token_start_idx), .kind = .close_parenthesis };
            },
            '[' => {
                self.current_char_idx += 1;
                return Token{ .pos = CodePosition.at(token_start_idx), .kind = .open_bracket };
            },
            ']' => {
                self.current_char_idx += 1;
                return Token{ .pos = CodePosition.at(token_start_idx), .kind = .close_bracket };
            },
            '0'...'9' => {
                const number: Token = try self.lex_number(false, token_start_idx);
                return number;
            },
            else => |chr| if (is_binary_message_char(chr)) {
                const token_end_idx = try self.lex_binary_message();
                const identifier = self.text[token_start_idx..token_end_idx];
                const token_position = CodePosition.from_start_and_end(
                    token_start_idx,
                    token_start_idx - 1,
                );

                // Check if the lex'ed identifier could be the 'pipe' token
                if (identifier.len == 1 and identifier[0] == '|') {
                    return Token{ .pos = token_position, .kind = .pipe };
                }

                // Check if the lex'ed identifier could be a negative sign in front of a number
                const current_char_is_digit = blk: {
                    const c = try self.current_char() orelse break :blk false;
                    break :blk std.ascii.isDigit(c);
                };
                if (identifier.len == 1 and identifier[0] == '-' and current_char_is_digit) {
                    return try self.lex_number(true, token_start_idx);
                }

                // Check if the lex'ed identifier could be the 'separator' token
                const consists_only_of_dashes: bool = std.mem.allEqual(u8, identifier, '-');
                if (identifier.len >= separator_minimum_length and consists_only_of_dashes) {
                    return Token{ .pos = token_position, .kind = .separator };
                }

                return Token{
                    .pos = token_position,
                    .kind = .{ .binary_message = identifier },
                };
            } else {
                self.reporter.report_error(
                    .{ .pos = CodePosition.at(token_start_idx) },
                    "Unexpected character: '{c}'",
                    .{chr},
                );
                return LexerError.unexpected_character;
            },
        }
    }

    fn current_char(self: *Self) LexerError!?u8 {
        if (self.current_char_idx >= self.text.len) {
            return null;
        }

        const peeked_char = self.text[self.current_char_idx];
        if (!std.ascii.isAscii(peeked_char)) {
            self.reporter.report_error(
                .{ .pos = CodePosition.at(self.current_char_idx) },
                "Found non ASCII character (value of byte is {d}). Sorry, we don't parse non ASCII unicode :)",
                .{peeked_char},
            );
            return LexerError.non_ascii_byte;
        }
        return peeked_char;
    }

    fn lex_number(self: *Self, had_minus: bool, token_start_idx: usize) LexerError!Token {
        const whole_part = self.lex_integer(had_minus) catch |err| {
            if (err == LexerError.number_literal_too_big) {
                self.reporter.report_error(
                    .{ .pos = CodePosition.from_start_and_end(
                        token_start_idx,
                        self.current_char_idx,
                    ) },
                    "This number literal is too big to fit into the internal representation for an integer.",
                    .{},
                );
            }
            return err;
        };
        const integer_token = Token{
            .kind = .{ .integer = whole_part },
            .pos = CodePosition.from_start_and_end(token_start_idx, self.current_char_idx),
        };

        // Now we do a bit of backtracking because of the strange SOM grammar (using dots to separate expressions)
        // .. because we need to check whether the current token is or is not a float literal.
        const current_chr = try self.current_char();
        const is_at_the_end = self.current_char_idx + 1 >= self.text.len;
        if (current_chr != '.' or is_at_the_end) {
            // We know the token does not continue with a decimal part.
            return integer_token;
        }

        const next_chr = self.text[self.current_char_idx + 1];
        if (!std.ascii.isDigit(next_chr)) {
            // We know the token does not continue with a decimal part.
            return integer_token;
        }
        // Ok.. now we know it is a double floating point number literal.
        self.current_char_idx += 1;
        const float_literal = try self.lex_decimal_part_of_float(whole_part);
        return Token{
            .pos = CodePosition.from_start_and_end(token_start_idx, self.current_char_idx),
            .kind = .{ .float = float_literal },
        };
    }

    fn skip_whitespace(self: *Self) LexerError!void {
        while (true) {
            const current_chr = try self.current_char() orelse return;
            if (!std.ascii.isWhitespace(current_chr)) return;
            self.current_char_idx += 1;
        }
    }

    fn lex_decimal_part_of_float(self: *Self, whole_part: IntegerRepr) LexerError!FloatRepr {
        const start_char = (try self.current_char()).?;
        std.debug.assert(std.mem.indexOfScalar(u8, digits, start_char) != null);

        var result: FloatRepr = @floatFromInt(whole_part);
        var power_of_10: FloatRepr = 10;

        loop: switch (try self.current_char() orelse 0) {
            '0'...'9' => |c| {
                const digit: FloatRepr = @floatFromInt(c - '0');
                result += digit / power_of_10;

                self.current_char_idx += 1;
                power_of_10 *= 10;
                continue :loop try self.current_char() orelse 0;
            },
            else => {
                return result;
            },
        }
        unreachable;
    }

    fn lex_integer(self: *Self, had_minus: bool) LexerError!i64 {
        const start_char = (try self.current_char()).?;
        std.debug.assert(std.mem.indexOfScalar(u8, digits, start_char) != null);
        var integer: IntegerRepr = start_char - '0';
        const sign: IntegerRepr = if (had_minus) -1 else 1;
        integer *= sign;

        self.current_char_idx += 1;

        var did_overflow = false;

        loop: switch (try self.current_char() orelse 0) {
            '0'...'9' => |chr| {
                if (!did_overflow) {
                    const digit = chr - '0';
                    integer = std.math.mul(IntegerRepr, integer, 10) catch blk: {
                        did_overflow = true;
                        break :blk 0;
                    };
                    integer = std.math.add(IntegerRepr, integer, digit * sign) catch blk: {
                        did_overflow = true;
                        break :blk 0;
                    };
                }

                self.current_char_idx += 1;
                continue :loop try self.current_char() orelse 0;
            },
            else => {
                if (did_overflow) {
                    return LexerError.number_literal_too_big;
                } else {
                    return integer;
                }
            },
        }
        unreachable;
    }

    /// Advances the lexer until it is no longer at a position that is part of an binary message identifier.
    /// Crashes (via `unreachable`) if the starting position of the lexer is not at the beginning of an identifier.
    ///
    /// Returns the end character index of the identifier (excluding end index) - which is the new `current_char_idx`
    /// of the lexer.
    fn lex_binary_message(self: *Self) LexerError!usize {
        std.debug.assert(is_binary_message_char((try self.current_char()).?));
        self.current_char_idx += 1;

        while (true) {
            const current_chr = try self.current_char() orelse break;
            if (!is_binary_message_char(current_chr)) {
                break;
            }
            self.current_char_idx += 1;
        }
        return self.current_char_idx;
    }

    /// Advances the lexer until it is no longer at a position that is part of an identifier.
    /// Crashes (via `unreachable`) if the starting position of the lexer is not at the beginning of an identifier.
    ///
    /// Returns the end character index of the identifier (excluding end index) - which is the new `current_char_idx`
    /// of the lexer.
    fn lex_identifier(self: *Self, can_have_colon_at_the_end: bool) LexerError!usize {
        std.debug.assert(std.mem.indexOfScalar(u8, identifier_start_chars, (try self.current_char()).?) != null);
        self.current_char_idx += 1;

        loop: switch (try self.current_char() orelse 0) {
            'a'...'z', 'A'...'Z', '_', '0'...'9' => {
                self.current_char_idx += 1;
                continue :loop try self.current_char() orelse 0;
            },
            else => |chr| {
                if (chr == ':' and can_have_colon_at_the_end) {
                    self.current_char_idx += 1;
                }
                return self.current_char_idx;
            },
        }
        unreachable;
    }
};
const digits = "0123456789";

fn is_binary_message_char(chr: u8) bool {
    return std.mem.indexOfScalar(u8, binary_message_chars, chr) != null;
}

const binary_message_chars =
    \\&@,/=<-\>~|%+*
;

/// Valid identifier starting characters
const identifier_start_chars = std.ascii.letters ++ "_";

/// Valid characters in an identifier (not at the beginning of the identifier)
const identifier_chars = identifier_start_chars ++ digits;

const separator_minimum_length = 4;

test "lex simple characters" {
    //                           012345
    const input = ".^()[]";
    var lexer = Lexer.create(input, ErrorReporter{});

    try std.testing.expectEqual(Token{
        .pos = CodePosition.at(0),
        .kind = .dot,
    }, lexer.next_token());

    try std.testing.expectEqual(Token{
        .pos = CodePosition.at(1),
        .kind = .exit,
    }, lexer.next_token());

    const next_expected_token = Token{
        .pos = CodePosition.at(2),
        .kind = .open_parenthesis,
    };
    for (0..4) |_| {
        try std.testing.expectEqual(next_expected_token, lexer.peek_token());
    }

    try std.testing.expectEqual(next_expected_token, lexer.next_token());

    try std.testing.expectEqual(Token{
        .pos = CodePosition.at(3),
        .kind = .close_parenthesis,
    }, lexer.next_token());

    try std.testing.expectEqual(Token{
        .pos = CodePosition.at(4),
        .kind = .open_bracket,
    }, lexer.next_token());

    try std.testing.expectEqual(Token{
        .pos = CodePosition.at(5),
        .kind = .close_bracket,
    }, try lexer.next_token());

    try std.testing.expectEqual(null, try lexer.next_token());
    try std.testing.expectEqual(null, try lexer.next_token());
    try std.testing.expectEqual(null, try lexer.peek_token());
    try std.testing.expectEqual(null, try lexer.next_token());
}

test "lex text with whitespace" {
    //                         012 34567 89
    const input: []const u8 = " .\n ^^[\t  ] ";
    var lexer = Lexer.create(input, ErrorReporter{});

    try std.testing.expectEqual(Token{
        .pos = CodePosition.at(1),
        .kind = .dot,
    }, try lexer.next_token());

    try std.testing.expectEqual(Token{
        .pos = CodePosition.at(4),
        .kind = .exit,
    }, try lexer.next_token());

    try std.testing.expectEqual(Token{
        .pos = CodePosition.at(5),
        .kind = .exit,
    }, try lexer.next_token());

    try std.testing.expectEqual(Token{
        .pos = CodePosition.at(6),
        .kind = .open_bracket,
    }, try lexer.next_token());

    try std.testing.expectEqual(Token{
        .pos = CodePosition.at(10),
        .kind = .close_bracket,
    }, try lexer.next_token());

    try std.testing.expectEqual(null, try lexer.next_token());
}

test "should error on non-ascii character" {
    const input = "^^" ++ .{ 130, 150 };
    var lexer = Lexer.create(input, .{});
    try std.testing.expectEqual(Token{
        .pos = CodePosition.at(0),
        .kind = .exit,
    }, try lexer.next_token());
    try std.testing.expectEqual(Token{
        .pos = CodePosition.at(1),
        .kind = .exit,
    }, try lexer.next_token());
    try std.testing.expectError(LexerError.non_ascii_byte, lexer.next_token());
}

test "lex identifiers" {
    //                                   10        20        30
    //                         01234567890123456789012345678901234
    const input: []const u8 = "Hello hoW_:  are :you _som9 :wrong: ";
    var lexer = Lexer.create(input, .{});

    try std.testing.expectEqual(Token{
        .pos = CodePosition.from_start_and_end(0, 4),
        .kind = .{ .identifier = input[0..5] },
    }, try lexer.next_token());

    try std.testing.expectEqual(Token{
        .pos = CodePosition.from_start_and_end(6, 10),
        .kind = .{ .keyword_message = input[6..11] },
    }, try lexer.next_token());

    try std.testing.expectEqual(Token{
        .pos = CodePosition.from_start_and_end(13, 15),
        .kind = .{ .identifier = input[13..16] },
    }, try lexer.next_token());

    try std.testing.expectEqual(Token{
        .pos = CodePosition.from_start_and_end(17, 20),
        .kind = .{ .block_param = input[17..21] },
    }, try lexer.next_token());

    try std.testing.expectEqual(Token{
        .pos = CodePosition.from_start_and_end(22, 26),
        .kind = .{ .identifier = input[22..27] },
    }, try lexer.next_token());

    try std.testing.expectEqual(Token{
        .pos = CodePosition.from_start_and_end(28, 33),
        .kind = .{ .block_param = input[28..34] },
    }, try lexer.next_token());

    try std.testing.expectError(LexerError.alone_colon, lexer.next_token());
}

// TODO: test lexing of binary messages
