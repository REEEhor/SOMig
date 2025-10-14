//
// TODO:
//  - [ ] Maybe a keyword sequence. Something like `run:this:with:that:`
//        This can be used with symbols like `#run:this:with:that:`
//
//  - [ ] Be able to lex number literals with multiple minuses.
//        Put that in `.saw_multiple_dashes`.
//

/// @baka-src Heavily inspired by the `tokenizer.zig` in the standard library.
const std = @import("std");
const error_reporter = @import("reporter.zig");
const ErrorReporter: type = error_reporter.ErrorReporter;
const string_literals_manager = @import("string_literals_manager.zig");
const StringLiteralsManager: type = string_literals_manager.StringLiteralsManager;

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
    unclosed_string_literal,
    invalid_escaped_character_in_string_literal,
} || string_literals_manager.Error;

const State = enum {
    start,
    inside_comment,
    lexing_identifier,
    saw_colon,
    saw_pipe,
    lexing_binary_message,
    saw_dash,
    saw_multiple_dashes,
};

pub const Lexer = struct {
    const Self = @This();
    current_char_idx: usize,
    text: []const u8,
    buffer_peeked_token: ?Token,
    reporter: ErrorReporter,
    string_literals: *StringLiteralsManager,

    pub fn create(input: []const u8, reporter: ErrorReporter, string_literals: *StringLiteralsManager) Self {
        return Lexer{
            .current_char_idx = 0,
            .text = input,
            .buffer_peeked_token = null,
            .reporter = reporter,
            .string_literals = string_literals,
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
                '0'...'9' => {
                    self.current_char_idx -= 1; // un-peek character
                    const number_token = try self.lex_number(false, token_start_idx);
                    return number_token;
                },
                '-' => continue :loop .saw_dash,
                '|' => continue :loop .saw_pipe,
                ':' => continue :loop .saw_colon,
                '"' => continue :loop .inside_comment,
                '\'' => {
                    const string_literal = try self.lex_string_literal(token_start_idx);
                    return string_literal;
                },
                '#' => {
                    if (try self.current_char() == '(') {
                        self.current_char_idx += 1;
                        return Token{
                            .pos = CodePosition.from_start_and_end(token_start_idx, self.current_char_idx - 1),
                            .kind = .array_literal_begin,
                        };
                    }
                    return Token{ .pos = CodePosition.at(token_start_idx), .kind = .hashtag };
                },
                else => |chr| {
                    if (std.ascii.isWhitespace(chr)) {
                        token_start_idx = self.current_char_idx;
                        continue :loop .start;
                    } else if (is_binary_message_char(chr)) {
                        continue :loop .lexing_binary_message;
                    } else {
                        self.reporter.report_error(
                            .{ .pos = CodePosition.at(token_start_idx) },
                            "Unexpected character: '{c}'",
                            .{chr},
                        );
                        return LexerError.unexpected_character;
                    }
                },
            },
            .saw_dash => switch (try self.current_char()) {
                '0'...'9' => {
                    // Encountered a negative number literal
                    const number_token = try self.lex_number(true, token_start_idx);
                    return number_token;
                },
                '-' => {
                    self.current_char_idx += 1;
                    continue :loop .saw_multiple_dashes;
                },
                else => |chr| if (is_binary_message_char(chr)) {
                    self.current_char_idx += 1;
                    continue :loop .lexing_binary_message;
                } else {
                    return Token{
                        .pos = CodePosition.at(token_start_idx),
                        .kind = .binary_message,
                    };
                },
            },
            .saw_multiple_dashes => switch (try self.current_char()) {
                '-' => {
                    self.current_char_idx += 1;
                    continue :loop .saw_multiple_dashes;
                },
                else => |chr| if (is_binary_message_char(chr)) {
                    continue :loop .lexing_binary_message;
                } else {
                    const token_position = CodePosition.from_start_and_end(token_start_idx, self.current_char_idx - 1);
                    if (token_position.length >= separator_minimum_length) {
                        return Token{ .pos = token_position, .kind = .separator };
                    }
                    return Token{ .pos = token_position, .kind = .binary_message };
                },
            },
            .saw_pipe => if (is_binary_message_char(try self.current_char())) {
                self.current_char_idx += 1;
                continue :loop .lexing_binary_message;
            } else {
                return Token{
                    .pos = CodePosition.at(token_start_idx),
                    .kind = .pipe,
                };
            },
            .saw_colon => switch (try self.eat_char()) {
                'a'...'z', 'A'...'Z', '_' => continue :loop .lexing_identifier,
                '=' => {
                    return Token{
                        .pos = CodePosition{ .start_idx = token_start_idx, .length = 2 },
                        .kind = .assign,
                    };
                },
                else => {
                    self.reporter.report_error(
                        .{ .pos = CodePosition.at(token_start_idx) },
                        "Found the ':' character on its own, which does not mean anything in SOM.",
                        .{},
                    );
                    self.reporter.add_note(.no_location, "Maybe it should be at the end of some `keywordMessage:` or at the beginning of some `:blockParameter`?", .{});
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
                        self.reporter.report_error(.{ .pos = CodePosition.at(token_start_idx) }, "Found the ':' character on its own.", .{});
                        self.reporter.add_note(.no_location, "Maybe it should be at the end of some `keywordMessage:` or at the beginning of some `:blockParameter`?", .{});
                        return LexerError.alone_colon;
                    }
                    if (first_char == ':') {
                        return Token{ .pos = token_position, .kind = .block_param };
                    }
                    return Token{ .pos = token_position, .kind = .identifier };
                },
            },
            .lexing_binary_message => if (is_binary_message_char(try self.current_char())) {
                self.current_char_idx += 1;
                continue :loop .lexing_binary_message;
            } else {
                return Token{
                    .pos = CodePosition.from_start_and_end(token_start_idx, self.current_char_idx - 1),
                    .kind = .binary_message,
                };
            },
            .inside_comment => switch (self.eat_unchecked_byte()) {
                '"' => {
                    token_start_idx = self.current_char_idx;
                    continue :loop .start;
                },
                eof => {
                    self.reporter.report_error(
                        .{ .pos = CodePosition.at(token_start_idx) },
                        "The comment that starts here does not have a closing '\"' character" ++
                            " - so the comment goes until the end of the file, which is probably not something you want :D",
                        .{},
                    );
                    return LexerError.unclosed_comment;
                },
                else => continue :loop .inside_comment,
            },
        }
        unreachable;
    }

    fn lex_string_literal(self: *Self, token_start_idx: usize) LexerError!Token {
        self.string_literals.start_new_literal();

        while (true) {
            switch (self.eat_unchecked_byte()) {
                '\'' => {
                    const string_contents = try self.string_literals.get_allocated_literal();
                    return Token{
                        .pos = CodePosition.from_start_and_end(token_start_idx, self.current_char_idx - 1),
                        .kind = .{ .string_literal = string_contents },
                    };
                },
                '\\' => {
                    switch (self.current_unchecked_char()) {
                        't' => try self.string_literals.append_to_current_literal('\t'),
                        'b' => try self.string_literals.append_to_current_literal(std.ascii.control_code.bel),
                        'n' => try self.string_literals.append_to_current_literal('\n'),
                        'r' => try self.string_literals.append_to_current_literal('\r'),
                        'f' => try self.string_literals.append_to_current_literal(std.ascii.control_code.ff),
                        '0' => try self.string_literals.append_to_current_literal(0),
                        '\\' => try self.string_literals.append_to_current_literal('\\'),
                        '\'' => try self.string_literals.append_to_current_literal('\''),
                        eof => {
                            self.reporter.report_error(.{
                                .pos = CodePosition.from_start_and_end(token_start_idx, self.current_char_idx - 1),
                            }, "This string literal is missing the delimitting `'` character at the end.", .{});
                            return LexerError.unclosed_string_literal;
                        },
                        else => |chr| {
                            self.reporter.report_error(
                                .{
                                    .pos = CodePosition.from_start_and_end(
                                        self.current_char_idx - 1, // Include the slash in the error.
                                        self.current_char_idx,
                                    ),
                                },
                                "Invalid escape sequence \"\\{c}\". Valid escape sequences in strings are: {s}.",
                                .{ chr, build_escapable_sequences_as_str() },
                            );
                            return LexerError.invalid_escaped_character_in_string_literal;
                        },
                    }
                    self.current_char_idx += 1;
                },
                eof, '\n' => {
                    self.reporter.report_error(.{
                        .pos = CodePosition.from_start_and_end(token_start_idx, self.current_char_idx - 1),
                    }, "This string literal is missing the delimitting `'` character at the end.", .{});
                    return LexerError.unclosed_string_literal;
                },
                else => |chr| {
                    try self.string_literals.append_to_current_literal(chr);
                },
            }
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

    fn current_unchecked_char(self: *Self) u8 {
        if (self.current_char_idx >= self.text.len) {
            return 0;
        }
        return self.text[self.current_char_idx];
    }

    fn current_char(self: *Self) LexerError!u8 {
        if (self.current_char_idx >= self.text.len) {
            return eof;
        }

        const peeked_char = self.text[self.current_char_idx];
        if (!std.ascii.isAscii(peeked_char)) {
            self.reporter.report_error(
                .{ .pos = CodePosition.at(self.current_char_idx) },
                "Found non ASCII character (value of byte is {d}). Sorry, we don't parse non ASCII unicode in identifiers :)",
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
            .pos = CodePosition.from_start_and_end(token_start_idx, self.current_char_idx - 1),
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
            .pos = CodePosition.from_start_and_end(token_start_idx, self.current_char_idx - 1),
            .kind = .{ .float = float_literal },
        };
    }

    fn lex_decimal_part_of_float(self: *Self, whole_part: IntegerRepr) LexerError!FloatRepr {
        const start_char = try self.current_char();
        std.debug.assert(std.ascii.isDigit(start_char));

        const sign: FloatRepr = if (whole_part < 0) -1 else 1;
        var result: FloatRepr = @floatFromInt(whole_part);
        var power_of_10: FloatRepr = 10;

        loop: switch (try self.current_char()) {
            '0'...'9' => |c| {
                const digit: FloatRepr = @floatFromInt(c - '0');
                result += sign * digit / power_of_10;

                self.current_char_idx += 1;
                power_of_10 *= 10;
                continue :loop try self.current_char();
            },
            else => {
                return result;
            },
        }
        unreachable;
    }

    fn lex_integer(self: *Self, had_minus: bool) LexerError!i64 {
        const start_char = try self.current_char();
        std.debug.assert(std.ascii.isDigit(start_char));
        var integer: IntegerRepr = start_char - '0';
        const sign: IntegerRepr = if (had_minus) -1 else 1;
        integer *= sign;

        self.current_char_idx += 1;

        var did_overflow = false;

        loop: switch (try self.current_char()) {
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
                continue :loop try self.current_char();
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
};

const digits = "0123456789";

fn is_binary_message_char(chr: u8) bool {
    return std.mem.indexOfScalar(u8, binary_message_chars, chr) != null;
}

const binary_message_chars = "&@,/=<-\\>~|%+*";
const escapable_characters = "tbnrf0\\";

fn build_escapable_sequences_as_str() []const u8 {
    comptime var result: [escapable_characters.len][]const u8 = undefined;
    result[0] = std.fmt.comptimePrint("\\{c}", .{escapable_characters[0]});

    inline for (escapable_characters, 0..) |chr, idx| {
        if (idx == 0) continue;
        result[idx] = comptime std.fmt.comptimePrint("{s}, \\{c}", .{ result[idx - 1], chr });
    }
    return result[result.len - 1];
}

const escapable_sequences_as_str = build_escapable_sequences_as_str();

/// Valid identifier starting characters
const identifier_start_chars = std.ascii.letters ++ "_";

/// Valid characters in an identifier (not at the beginning of the identifier)
const identifier_chars = identifier_start_chars ++ digits;

const separator_minimum_length = 4;

test "lex simple characters" {
    // Indexes into the input string:
    //                           012345
    const input = ".^()[]";
    var lexer = Lexer.create(input, ErrorReporter{}, undefined);

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

test "lex the assign token" {
    // Indexes into the input string:
    //                         0123456789
    const input: []const u8 = " := . := ";
    var lexer = Lexer.create(input, ErrorReporter{}, undefined);

    try assert_same_token(CodePosition{ .start_idx = 1, .length = 2 }, .assign, try lexer.next_token());
    try assert_same_token(CodePosition.at(4), .dot, try lexer.next_token());
    try assert_same_token(CodePosition{ .start_idx = 6, .length = 2 }, .assign, try lexer.next_token());
    try std.testing.expectEqual(null, try lexer.next_token());
}

fn assert_same_token(expected_pos: CodePosition, expected_kind: TokenKind, actual_maybe: ?Token) !void {
    try std.testing.expect(actual_maybe != null);
    const actual: Token = actual_maybe.?;

    try std.testing.expectEqual(expected_kind, actual.kind);

    try std.testing.expectEqual(expected_pos.start_idx, actual.pos.start_idx);
    try std.testing.expectEqual(expected_pos.length, actual.pos.length);
}

fn assert_string_literal_token(expected_pos: CodePosition, expected_text: []const u8, actual_maybe: ?Token) !void {
    try std.testing.expect(actual_maybe != null);
    const actual: Token = actual_maybe.?;

    switch (actual.kind) {
        .string_literal => |actual_text| {
            try std.testing.expectEqualStrings(expected_text, actual_text);
        },
        else => {
            std.debug.print("Expected a string literal loken, but got: `{s}`\n", .{@tagName(actual.kind)});
            return error.TokenIsNotStringLiteral;
        },
    }
    try std.testing.expectEqual(expected_pos.start_idx, actual.pos.start_idx);
    try std.testing.expectEqual(expected_pos.length, actual.pos.length);
}

test "lex text with comments" {
    const input: []const u8 =
        // Indexes into the input string:
        //          10        20        30        40        50        60
        //01234567890123456789012345678901234567890123456789012345678901234
        \\." This is some comment"^"Another comment"("""""""Final comment")
    ;
    var lexer = Lexer.create(input, ErrorReporter{}, undefined);

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
    var lexer = Lexer.create(input, ErrorReporter{}, undefined);

    try assert_same_token(CodePosition.at(1), .dot, try lexer.next_token());
    try assert_same_token(CodePosition.at(5), .exit, try lexer.next_token());
    try assert_same_token(CodePosition.at(6), .exit, try lexer.next_token());
    try assert_same_token(CodePosition.at(7), .open_bracket, try lexer.next_token());
    try assert_same_token(CodePosition.at(66), .close_bracket, try lexer.next_token());
    try std.testing.expectEqual(null, try lexer.next_token());
}

test "should error on non-ascii character" {
    const input = "^^" ++ .{ 130, 150 };
    var lexer = Lexer.create(input, .{}, undefined);
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
    var lexer = Lexer.create(input, .{}, undefined);

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

test "lex number" {
    // Indexes into the input string:
    //                                   10        20        30
    //                         01234567890123456789012345678901234
    const input: []const u8 = "  3  42  85769  2.0  9. 3.1415 5";
    var lexer = Lexer.create(input, .{}, undefined);

    try assert_same_token(
        CodePosition.at(2),
        .{ .integer = 3 },
        try lexer.next_token(),
    );

    try assert_same_token(
        CodePosition.from_start_and_end(5, 6),
        .{ .integer = 42 },
        try lexer.next_token(),
    );

    try assert_same_token(
        CodePosition.from_start_and_end(9, 13),
        .{ .integer = 85769 },
        try lexer.next_token(),
    );

    try assert_same_token(
        CodePosition.from_start_and_end(16, 18),
        .{ .float = 2.0 },
        try lexer.next_token(),
    );

    try assert_same_token(
        CodePosition.from_start_and_end(21, 21),
        .{ .integer = 9 },
        try lexer.next_token(),
    );

    try assert_same_token(
        CodePosition.from_start_and_end(22, 22),
        .dot,
        try lexer.next_token(),
    );

    try assert_same_token(
        CodePosition.from_start_and_end(24, 29),
        .{ .float = 3.1415 },
        try lexer.next_token(),
    );

    try assert_same_token(
        CodePosition.from_start_and_end(31, 31),
        .{ .integer = 5 },
        try lexer.next_token(),
    );

    try std.testing.expectEqual(null, try lexer.next_token());
}

test "lex negative number" {
    // Indexes into the input string:
    //                                   10        20        30
    //                         012345678901234567890123456789012345678
    const input: []const u8 = "  42  -5  -97    3  -253 -2.1  -43.472";
    var lexer = Lexer.create(input, .{}, undefined);

    try assert_same_token(
        CodePosition.from_start_and_end(2, 3),
        .{ .integer = 42 },
        try lexer.next_token(),
    );

    try assert_same_token(
        CodePosition.from_start_and_end(6, 7),
        .{ .integer = -5 },
        try lexer.next_token(),
    );

    try assert_same_token(
        CodePosition.from_start_and_end(10, 12),
        .{ .integer = -97 },
        try lexer.next_token(),
    );

    try assert_same_token(
        CodePosition.from_start_and_end(17, 17),
        .{ .integer = 3 },
        try lexer.next_token(),
    );

    try assert_same_token(
        CodePosition.from_start_and_end(20, 23),
        .{ .integer = -253 },
        try lexer.next_token(),
    );

    try assert_same_token(
        CodePosition.from_start_and_end(25, 28),
        .{ .float = -2.1 },
        try lexer.next_token(),
    );

    try assert_same_token(
        CodePosition.from_start_and_end(31, 37),
        .{ .float = -43.472 },
        try lexer.next_token(),
    );

    try std.testing.expectEqual(null, try lexer.next_token());
}

test "lex single-char binary message" {
    var buffer: [1]u8 = undefined;
    for (binary_message_chars) |chr| {
        buffer[0] = chr;
        var lexer = Lexer.create(&buffer, .{}, undefined);
        const got_token = try lexer.next_token();
        if (chr == '|') {
            try assert_same_token(CodePosition.at(0), .pipe, got_token);
        } else {
            try assert_same_token(CodePosition.at(0), .binary_message, got_token);
        }
    }
}

test "lex two-char binary message" {
    var buffer: [2]u8 = undefined;
    for (binary_message_chars) |chr0| {
        buffer[0] = chr0;
        for (binary_message_chars) |chr1| {
            buffer[1] = chr1;
            var lexer = Lexer.create(&buffer, .{}, undefined);
            const got_token = try lexer.next_token();

            try assert_same_token(CodePosition.from_start_and_end(0, 1), .binary_message, got_token);
            try std.testing.expectEqual(null, try lexer.next_token());
        }
    }
}

test "lex separator" {
    var buffer: []const u8 = "----------";
    for (1..buffer.len) |len| {
        const input = buffer[0..len];
        const expected_kind: TokenKind = if (len >= separator_minimum_length) .separator else .binary_message;

        var lexer = Lexer.create(input, .{}, undefined);
        const got_token = try lexer.next_token();

        try assert_same_token(CodePosition.from_start_and_end(0, len - 1), expected_kind, got_token);
        try std.testing.expectEqual(null, try lexer.next_token());
    }
}

test "lex empty string literal" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    var strings_manager = StringLiteralsManager.create(arena_allocator.allocator(), std.testing.allocator, 0) catch unreachable;
    defer strings_manager.deinit();

    const input = "''";
    var lexer = Lexer.create(input, .{}, &strings_manager);

    try assert_string_literal_token(CodePosition.from_start_and_end(0, 1), "", try lexer.next_token());
    try std.testing.expectEqual(null, try lexer.next_token());
}

test "lex simple string literal" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    var strings_manager = StringLiteralsManager.create(arena_allocator.allocator(), std.testing.allocator, 0) catch unreachable;
    defer strings_manager.deinit();

    // Indexes into the input string:
    //             012345
    const input = "'ahoj'";
    var lexer = Lexer.create(input, .{}, &strings_manager);

    try assert_string_literal_token(CodePosition.from_start_and_end(0, 5), "ahoj", try lexer.next_token());
    try std.testing.expectEqual(null, try lexer.next_token());
}

test "lex multiple string literals" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    var strings_manager = StringLiteralsManager.create(arena_allocator.allocator(), std.testing.allocator, 0) catch unreachable;
    defer strings_manager.deinit();

    // Indexes into the input string:
    //                       10        20
    //             0123456789012345678901234567
    const input = "  'Ahoj!' 'jak' 'se'  'mas?' ";
    var lexer = Lexer.create(input, .{}, &strings_manager);

    try assert_string_literal_token(CodePosition.from_start_and_end(2, 8), "Ahoj!", try lexer.next_token());
    try assert_string_literal_token(CodePosition.from_start_and_end(10, 14), "jak", try lexer.next_token());
    try assert_string_literal_token(CodePosition.from_start_and_end(16, 19), "se", try lexer.next_token());
    try assert_string_literal_token(CodePosition.from_start_and_end(22, 27), "mas?", try lexer.next_token());

    try std.testing.expectEqual(null, try lexer.next_token());
}

test "lex a string literals with escape codes" {
    var arena_allocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_allocator.deinit();
    var strings_manager = StringLiteralsManager.create(arena_allocator.allocator(), std.testing.allocator, 0) catch unreachable;
    defer strings_manager.deinit();

    const input =
        // Indexes into the input string:
        //          10        20        30        40
        //01234567890123456789012345678901234567890123456789
        \\'Newline \n was here' 'or tab \t was also \t here'
    ;
    var lexer = Lexer.create(input, .{}, &strings_manager);

    try assert_string_literal_token(
        CodePosition.from_start_and_end(0, 20),
        "Newline \n was here",
        try lexer.next_token(),
    );
    try assert_string_literal_token(
        CodePosition.from_start_and_end(22, 49),
        "or tab \t was also \t here",
        try lexer.next_token(),
    );

    try std.testing.expectEqual(null, try lexer.next_token());
}

// TODO: test all special characters

test "snapshot test on example files" {
    const snapshot_options = @import("snapshot_test_options");

    const path = snapshot_options.snapshot_testing_path;
    std.debug.print("\n[DEBUG] Path to SOM files for snapshot testing: '{s}'\n", .{path});
    // TODO: check if the path string is not empty for a better error message
}
