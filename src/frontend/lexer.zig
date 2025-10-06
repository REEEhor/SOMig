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
const eof = 0;

pub const LexerError = error{
    unexpected_character,
    alone_colon,
    colon_at_both_identifier_ends,
    non_ascii_byte,
    number_literal_too_big,
    unclosed_comment,
};

const State = enum {
    start,
    inside_comment,
    lexing_identifier,
    saw_colon,
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
        var token_start_idx = self.current_char_idx;

        loop: switch (State.start) {
            .start => switch (try self.eat_char()) {
                eof => return null,
                '^' => return Token{ .pos = CodePosition.at(token_start_idx), .kind = .exit },
                '.' => return Token{ .pos = CodePosition.at(token_start_idx), .kind = .dot },
                '(' => return Token{ .pos = CodePosition.at(token_start_idx), .kind = .open_parenthesis },
                ')' => return Token{ .pos = CodePosition.at(token_start_idx), .kind = .close_parenthesis },
                '[' => return Token{ .pos = CodePosition.at(token_start_idx), .kind = .open_bracket },
                ']' => return Token{ .pos = CodePosition.at(token_start_idx), .kind = .close_bracket },
                'a'...'z', 'A'...'Z', '_' => continue :loop .lexing_identifier,
                ':' => continue :loop .saw_colon,
                '"' => continue :loop .inside_comment,
                else => |chr| if (std.ascii.isWhitespace(chr)) {
                    token_start_idx = self.current_char_idx;
                    continue :loop .start;
                } else {
                    self.reporter.report_error(
                        .{ .pos = CodePosition.at(token_start_idx) },
                        "Unexpected character: '{c}'",
                        .{chr},
                    );
                    return LexerError.unexpected_character;
                },
            },
            .saw_colon => switch (try self.eat_char()) {
                'a'...'z', 'A'...'Z', '_' => continue :loop .lexing_identifier,
                else => {
                    self.reporter.report_error(.{ .pos = CodePosition.at(token_start_idx) },
                        \\Found the ':' character on its own.
                        \\ Maybe it should be at the end of some `keywordMessage:` or at the beginning of some `:blockParameter`?
                    , .{});
                    return LexerError.alone_colon;
                },
            },
            .lexing_identifier => switch (try self.current_char()) {
                'a'...'z', 'A'...'Z', '_', '0'...'9' => {
                    self.current_char_idx += 1;
                    continue :loop .lexing_identifier;
                },
                ':' => {
                    self.current_char_idx += 1;
                    if (self.text[token_start_idx] == ':') {
                        const error_pos = CodePosition.from_start_and_end(
                            token_start_idx,
                            self.current_char_idx - 1,
                        );
                        if (error_pos.length == 2) {
                            self.reporter.report_error(
                                .{ .pos = error_pos },
                                "Found two colons \"::\" after each other. This does not mean anything in SOM.",
                                .{},
                            );
                            return LexerError.colon_at_both_identifier_ends;
                        }

                        const identifier = self.text[token_start_idx..self.current_char_idx];
                        self.reporter.report_error(
                            .{ .pos = error_pos },
                            "Found an identifier \"{s}\", which is surrounded by colon ':' on both sides. This syntax does not mean anytning in SOM.",
                            .{identifier},
                        );
                        // @nice-to-have: Move this note into the parser, so it actually can infer, whether the user probably
                        //                wanted `keywordMessage:` or `:blockParameter`.
                        self.reporter.add_note(
                            .no_location,
                            "You might have wanted to do either a keyword message," ++
                                " which would be \"{s}\" or a parameter of a block, which would be \"{s}\" :)",
                            .{ self.text[token_start_idx + 1 .. self.current_char_idx], self.text[token_start_idx .. self.current_char_idx - 1] },
                        );
                        return LexerError.colon_at_both_identifier_ends;
                    } else {
                        return Token{
                            .pos = CodePosition.from_start_and_end(token_start_idx, self.current_char_idx - 1),
                            .kind = .keyword_message,
                        };
                    }
                },
                else => {
                    const first_char = self.text[token_start_idx];
                    const token_position = CodePosition.from_start_and_end(
                        token_start_idx,
                        self.current_char_idx - 1,
                    );
                    self.current_char_idx += 1;

                    if (first_char == ':' and token_position.length == 1) {
                        // @nice-to-have: Add the second line as a note via `self.reporter.add_note(...)`
                        self.reporter.report_error(.{ .pos = CodePosition.at(token_start_idx) },
                            \\Found the ':' character on its own.
                            \\ Maybe it should be at the end of some `keywordMessage:` or at the beginning of some `:blockParameter`?
                        , .{});
                        return LexerError.alone_colon;
                    }
                    if (first_char == ':') {
                        return Token{ .pos = token_position, .kind = .block_param };
                    }
                    return Token{ .pos = token_position, .kind = .identifier };
                },
            },
            .inside_comment => switch (self.eat_unchecked_byte()) {
                '"' => {
                    token_start_idx = self.current_char_idx;
                    continue :loop .start;
                },
                eof => {
                    self.reporter.report_error(.{ .pos = CodePosition.at(token_start_idx) },
                        \\The comment that starts here does not have a closing '"' character
                        \\ - so the comment goes until the end of the file, which is probably not something you want :D
                    , .{});
                    return LexerError.unclosed_comment;
                },
                else => continue :loop .inside_comment,
            },
        }
        unreachable;
    }

    fn eat_unchecked_byte(self: *Self) u8 {
        if (self.current_char_idx >= self.text.len) {
            return 0;
        }
        const chr = self.text[self.current_char_idx];
        self.current_char_idx += 1;
        return chr;
    }

    fn eat_char(self: *Self) LexerError!u8 {
        const chr = try self.current_char();
        self.current_char_idx += 1;
        return chr;
    }

    fn current_char(self: *Self) LexerError!u8 {
        if (self.current_char_idx >= self.text.len) {
            return 0;
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
    // Indexes into the input string:
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

fn assert_same_token(expected_pos: CodePosition, expected_kind: TokenKind, actual_maybe: ?Token) !void {
    try std.testing.expect(actual_maybe != null);
    const actual: Token = actual_maybe.?;

    try std.testing.expectEqual(expected_pos.start_idx, actual.pos.start_idx);
    try std.testing.expectEqual(expected_pos.length, actual.pos.length);

    try std.testing.expectEqual(expected_kind, actual.kind);
}

test "lex text with comments" {
    const input: []const u8 =
        // Indexes into the input string:
        //          10        20        30        40        50        60
        //01234567890123456789012345678901234567890123456789012345678901234
        \\." This is some comment"^"Another comment"("""""""Final comment")
    ;
    var lexer = Lexer.create(input, ErrorReporter{});

    try assert_same_token(CodePosition.at(0), .dot, try lexer.next_token());
    try assert_same_token(CodePosition.at(24), .exit, try lexer.next_token());
    try assert_same_token(CodePosition.at(42), .open_parenthesis, try lexer.next_token());
    try assert_same_token(CodePosition.at(64), .close_parenthesis, try lexer.next_token());
}

test "lex text with whitespace and comments" {
    // Indexes into the input string:
    //                                       10         20        30         40         50        60
    //                         012 3 4 5678 90 12345678901234567890123  7 89 012 345678901234567890123 456
    const input: []const u8 = " .\n\"\"^^[\t \" Hi! this is a comment Ř \"  \n  \" Double comment! :D \" ] \" Also a comment at the end :)\"";
    var lexer = Lexer.create(input, ErrorReporter{});

    try assert_same_token(CodePosition.at(1), .dot, try lexer.next_token());
    try assert_same_token(CodePosition.at(5), .exit, try lexer.next_token());
    try assert_same_token(CodePosition.at(6), .exit, try lexer.next_token());
    try assert_same_token(CodePosition.at(7), .open_bracket, try lexer.next_token());
    try assert_same_token(CodePosition.at(66), .close_bracket, try lexer.next_token());
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
    // Indexes into the input string:
    //                                   10        20        30
    //                         01234567890123456789012345678901234
    const input: []const u8 = "Hello hoW_:  are :you _som9 :wrong: ";
    var lexer = Lexer.create(input, .{});

    try assert_same_token(
        CodePosition.from_start_and_end(0, 4),
        .identifier,
        try lexer.next_token(),
    );

    try std.testing.expectEqual(Token{
        .pos = CodePosition.from_start_and_end(6, 10),
        .kind = .keyword_message,
    }, try lexer.next_token());

    try std.testing.expectEqual(Token{
        .pos = CodePosition.from_start_and_end(13, 15),
        .kind = .identifier,
    }, try lexer.next_token());

    try std.testing.expectEqual(Token{
        .pos = CodePosition.from_start_and_end(17, 20),
        .kind = .block_param,
    }, try lexer.next_token());

    try std.testing.expectEqual(Token{
        .pos = CodePosition.from_start_and_end(22, 26),
        .kind = .identifier,
    }, try lexer.next_token());

    try std.testing.expectError(
        LexerError.colon_at_both_identifier_ends,
        lexer.next_token(),
    );
}

// TODO: test lexing of binary messages
