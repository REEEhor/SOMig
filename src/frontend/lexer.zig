/// NOTE(baka-src): Heavily inspired by the `tokenizer.zig` in the standard library.
const std = @import("std");
const Allocator = std.mem.Allocator;

const dbg = @import("../debug/debug.zig").dbg;

const error_reporter = @import("reporter.zig");
const ErrorReporter: type = error_reporter.ErrorReporter;
const debug_reporter = error_reporter.debug_reporter;

pub const token_module = @import("token.zig");
pub const minimal_separator_length = token_module.minimal_separator_length;
pub const Token = token_module.Token;
pub const TokenKind = token_module.TokenKind;
pub const CodePosition = token_module.CodePosition;
pub const IntegerRepr = token_module.IntegerRepresentation;
pub const FloatRepr = token_module.FloatRepresentation;
pub const TokenSpan = token_module.TokenSpan;
pub const TokenizedFile = token_module.TokenizedFile;
pub const TokenId = token_module.TokenId;
pub const TokenSpanIterator = token_module.TokenSpanIterator;

const State = enum {
    start,
    inside_comment,
    lexing_identifier,
    saw_colon,
    lexing_binary_message,
    saw_dash,
    saw_multiple_dashes,
    lexing_string_literal,
};

pub const Lexer = struct {
    current_char_idx: u32,
    source_code: []const u8,
    reporter: *ErrorReporter,

    const eof = 0;
    const Self = @This();
    pub const Error = error{
        unexpected_character,
        alone_colon,
        colon_at_both_identifier_ends,
        non_ascii_byte,
        number_literal_too_big,
        unclosed_comment,
        unclosed_string_literal,
        invalid_escaped_character_in_string_literal,
    };

    pub fn create(input: []const u8, reporter: *ErrorReporter) Self {
        return Lexer{
            .current_char_idx = 0,
            .source_code = input,
            .reporter = reporter,
        };
    }

    /// Returning `null` means eof.
    pub fn next_token(self: *Self) Lexer.Error!?Token {
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
                    const number_token = try self.lex_number(token_start_idx);
                    return number_token;
                },
                '-' => continue :loop .saw_dash,
                ':' => continue :loop .saw_colon,
                '"' => continue :loop .inside_comment,
                '\'' => {
                    continue :loop .lexing_string_literal;
                },
                '#' => {
                    if (try self.current_char() == '(') {
                        self.current_char_idx += 1;
                        return Token{
                            .kind = .array_literal_begin,
                            .pos = CodePosition.from_start_and_end(token_start_idx, self.current_char_idx - 1),
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
                        return Error.unexpected_character;
                    }
                },
            },
            .lexing_string_literal => {
                switch (self.eat_unchecked_byte()) {
                    '\'' => return Token{
                        .kind = .string_literal,
                        .pos = CodePosition.from_start_and_end(token_start_idx, self.current_char_idx - 1),
                    },
                    '\\' => {
                        // We want to catch this case in the error handling below
                        // This would be triggered when an unclosed string literal would end with '\'
                        if (self.current_unchecked_char() == '\n') {
                            @branchHint(.cold);
                        } else {
                            self.current_char_idx += 1; // Skip the next character
                        }
                    },
                    eof => {
                        self.reporter.report_error(.{
                            .pos = CodePosition.from_start_and_end(token_start_idx, self.current_char_idx - 1),
                        }, "This string literal is missing the delimitting `'` character at the end.", .{});
                        return Error.unclosed_string_literal;
                    },
                    else => {},
                }
                continue :loop .lexing_string_literal;
            },
            .saw_dash => switch (try self.current_char()) {
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
                        .kind = .binary_selector,
                    };
                },
            },
            .saw_multiple_dashes => switch (try self.current_char()) {
                '-' => {
                    self.current_char_idx += 1;
                    continue :loop .saw_multiple_dashes;
                },
                else => |chr| if (is_binary_message_char(chr)) {
                    self.current_char_idx += 1;
                    continue :loop .lexing_binary_message;
                } else {
                    const pos = CodePosition.from_start_and_end(token_start_idx, self.current_char_idx - 1);
                    const kind: TokenKind = if (pos.length < minimal_separator_length) .binary_selector else .separator;
                    return Token{ .kind = kind, .pos = pos };
                },
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
                    @branchHint(.cold);
                    self.reporter.report_error(
                        .{ .pos = CodePosition.at(token_start_idx) },
                        "Found the ':' character on its own, which does not mean anything in SOM.",
                        .{},
                    );
                    self.reporter.add_note(.no_location, "Maybe it should be at the end of some `keywordMessage:` or at the beginning of some `:blockParameter`?", .{});
                    return Error.alone_colon;
                },
            },
            .lexing_identifier => switch (try self.current_char()) {
                'a'...'z', 'A'...'Z', '_', '0'...'9' => {
                    self.current_char_idx += 1;
                    continue :loop .lexing_identifier;
                },
                // FIXME: Fix parsing of colons
                ':' => {
                    self.current_char_idx += 1;
                    if (self.source_code[token_start_idx] == ':') {
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
                            return Error.colon_at_both_identifier_ends;
                        }

                        const identifier = self.source_code[token_start_idx..self.current_char_idx];
                        self.reporter.report_error(
                            .{ .pos = error_pos },
                            "Found an identifier \"{s}\", which is surrounded by colon ':' on both sides. This syntax does not mean anytning in SOM.",
                            .{identifier},
                        );
                        self.reporter.add_note(
                            .no_location,
                            "You might have wanted to do either a keyword message," ++
                                " which would be \"{s}\" or a parameter of a block, which would be \"{s}\" :)",
                            .{ self.source_code[token_start_idx + 1 .. self.current_char_idx], self.source_code[token_start_idx .. self.current_char_idx - 1] },
                        );
                        return Error.colon_at_both_identifier_ends;
                    } else {
                        return Token{
                            .pos = CodePosition.from_start_and_end(token_start_idx, self.current_char_idx - 1),
                            .kind = .keyword,
                        };
                    }
                },
                else => {
                    const first_char = self.source_code[token_start_idx];
                    const token_position = CodePosition.from_start_and_end(
                        token_start_idx,
                        self.current_char_idx - 1,
                    );

                    if (first_char == ':' and token_position.length == 1) {
                        self.reporter.report_error(.{ .pos = CodePosition.at(token_start_idx) }, "Found the ':' character on its own.", .{});
                        self.reporter.add_note(.no_location, "Maybe it should be at the end of some `keywordMessage:` or at the beginning of some `:blockParameter`?", .{});
                        return Error.alone_colon;
                    }
                    if (first_char == ':') {
                        return Token{ .pos = token_position, .kind = .block_param };
                    }
                    return Token{ .pos = token_position, .kind = .identifier };
                },
            },

            // We can do `current_unchecked_char` here, since it is either a valid binary message
            // or it an invalid byte in which case, it will be found in the next call to `next_token`.
            .lexing_binary_message => if (is_binary_message_char(self.current_unchecked_char())) {
                self.current_char_idx += 1;
                continue :loop .lexing_binary_message;
            } else {
                return Token{
                    .kind = .binary_selector,
                    .pos = CodePosition.from_start_and_end(token_start_idx, self.current_char_idx - 1),
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
                    return Error.unclosed_comment;
                },
                else => continue :loop .inside_comment,
            },
        }
        unreachable;
    }

    inline fn binary_message_or_separator(start_token_idx: usize, end_token_idx: usize) Token {
        const pos = CodePosition.from_start_and_end(start_token_idx, end_token_idx);
        const kind = if (pos.length >= minimal_separator_length) .separator else .binary_message;
        return Token{ .pos = pos, .kind = kind };
    }

    inline fn eat_unchecked_byte(self: *Self) u8 {
        if (self.current_char_idx >= self.source_code.len) {
            return 0;
        }
        const chr = self.source_code[self.current_char_idx];
        self.current_char_idx += 1;
        return chr;
    }

    inline fn eat_char(self: *Self) Lexer.Error!u8 {
        const chr = try self.current_char();
        self.current_char_idx += 1;
        return chr;
    }

    inline fn current_unchecked_char(self: *Self) u8 {
        if (self.current_char_idx >= self.source_code.len) {
            return 0;
        }
        return self.source_code[self.current_char_idx];
    }

    inline fn current_char(self: *Self) Lexer.Error!u8 {
        if (self.current_char_idx >= self.source_code.len) {
            return eof;
        }

        const peeked_char = self.source_code[self.current_char_idx];
        if (!std.ascii.isAscii(peeked_char)) {
            @branchHint(.cold);
            self.reporter.report_error(
                .{ .pos = CodePosition.at(self.current_char_idx) },
                "Found non ASCII character (value of byte is {d}). Sorry, we don't parse non ASCII unicode in identifiers :)",
                .{peeked_char},
            );
            return Error.non_ascii_byte;
        }
        return peeked_char;
    }

    inline fn lex_number(self: *Self, token_start_idx: u32) Lexer.Error!Token {
        try self.lex_integer();

        const integer_token = Token{
            .kind = .integer,
            .pos = CodePosition.from_start_and_end(token_start_idx, self.current_char_idx - 1),
        };

        // Now we do a bit of backtracking because of the strange SOM grammar (using dots to separate expressions)
        // .. because we need to check whether the current token is or is not a float literal.
        const current_chr = try self.current_char();
        const is_at_the_end = self.current_char_idx + 1 >= self.source_code.len;
        if (current_chr != '.' or is_at_the_end) {
            // We know the token does not continue with a decimal part.
            return integer_token;
        }

        const next_chr = self.source_code[self.current_char_idx + 1];
        if (!std.ascii.isDigit(next_chr)) {
            // We know the token does not continue with a decimal part.
            return integer_token;
        }
        // Ok.. now we know it is a double floating point number literal.
        self.current_char_idx += 1;
        try self.lex_integer();
        return Token{
            .kind = .float,
            .pos = CodePosition.from_start_and_end(token_start_idx, self.current_char_idx - 1),
        };
    }

    inline fn lex_integer(self: *Self) Lexer.Error!void {
        loop: switch (try self.current_char()) {
            '0'...'9' => {
                self.current_char_idx += 1;
                continue :loop try self.current_char();
            },
            else => return,
        }
        unreachable;
    }
};

pub const LexingError = Lexer.Error || Allocator.Error;

pub fn tokenize(params: struct {
    allocator: Allocator,
    source_code: []const u8,
    source_code_filepath: ?[]const u8,
    reporter: *ErrorReporter,
}) LexingError!TokenizedFile {
    const allocator = params.allocator;
    const source_code = params.source_code;
    const source_code_filepath = params.source_code_filepath;
    const reporter = params.reporter;

    var lexer = Lexer.create(source_code, reporter);
    var tokens = std.MultiArrayList(Token).empty;

    // Prealocate some elements
    // NOTE: Arbitrary choice, which grows together with the length of the source code.
    const assumed_number_of_tokens = source_code.len / 3;
    try tokens.ensureTotalCapacity(allocator, assumed_number_of_tokens);
    while (try lexer.next_token()) |t| {
        tokens.appendAssumeCapacity(t);
        if (tokens.len == assumed_number_of_tokens) break;
    }
    while (try lexer.next_token()) |t| {
        try tokens.append(allocator, t);
    }

    return TokenizedFile{
        .tokens = tokens.toOwnedSlice(),
        .source_code = source_code,
        .source_code_filepath = source_code_filepath,
    };
}

const digits = "0123456789";

pub inline fn is_binary_message_char(chr: u8) bool {
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

pub const separator_minimum_length = 4;

pub const testing = struct {
    pub const ExpectedToken = struct {
        kind: TokenKind,
        text: []const u8,
        start_idx: usize,
        end_idx: usize,

        pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.print("\"{s}\" (kind is: {t})", .{ self.text, self.kind });
        }
    };

    pub fn e(kind: TokenKind, text: []const u8, pos_idx: usize) ExpectedToken {
        return ExpectedToken{
            .kind = kind,
            .text = text,
            .start_idx = pos_idx,
            .end_idx = pos_idx + text.len - 1,
        };
    }

    fn test_lexer(
        source_code: []const u8,
        expected_tokens: []const ExpectedToken,
        expected_error_at_end: ?LexingError,
    ) !void {
        var d = debug_reporter(source_code);
        defer d.deinit();
        errdefer d.dump_errors();

        const expected_length = expected_tokens.len;

        var lexer = Lexer.create(source_code, &d.wrapped_reporter);

        for (0..expected_length) |idx| {
            const expected = expected_tokens[idx];
            const maybe_actual = lexer.next_token() catch |err| {
                std.debug.print("Unexpected error in lexer test for idx={d}:\n", .{idx});
                std.debug.print("  Expected: {f}\n", .{expected});
                std.debug.print("  Got error: {t}\n", .{err});
                return error.unexpected_error;
            };
            if (maybe_actual == null) {
                std.debug.print("Unexpected EOF in lexer test for idx={d}:\n", .{idx});
                std.debug.print("  Expected: {f}\n", .{expected});
                std.debug.print("  Got error: null (meaning EOF)\n", .{});
                return error.unexpected_eof;
            }
            const actual_token = maybe_actual.?;

            const actual_text = actual_token.pos.slice_from(source_code);
            if (!std.mem.eql(u8, actual_text, expected.text)) {
                std.debug.print("Unexpected text of token in lexer test for idx={d}:\n", .{idx});
                std.debug.print("  Expected: >{s}<\n", .{expected.text});
                std.debug.print("  Got text: >{s}<\n", .{actual_text});
                return error.unexpected_token_text;
            }

            if (actual_token.kind != expected.kind) {
                std.debug.print("Unexpected kind of token in lexer test for idx={d}:\n", .{idx});
                std.debug.print("  Expected: {f}\n", .{expected});
                std.debug.print("  Got kind: {t}\n", .{actual_token.kind});
                return error.unexpected_token_kind;
            }

            if (actual_token.pos.start_idx != expected.start_idx or actual_token.pos.end_idx_inclusive() != expected.end_idx) {
                std.debug.print("Unexpected position of token in lexer test for idx={d}:\n", .{idx});
                std.debug.print("  Expected: {d}..{d}\n", .{ expected.start_idx, expected.end_idx });
                std.debug.print("  Got:      {d}..{d}\n", .{ actual_token.pos.start_idx, actual_token.pos.end_idx_inclusive() });
                std.debug.print("The kind ({t}) and text >{s}< matches\n", .{ expected.kind, expected.text });
                return error.unexpected_token_kind;
            }
        }

        if (expected_error_at_end) |expected_error| {
            const actual_error: LexingError = blk: {
                const t: ?Token = lexer.next_token() catch |err| break :blk err;
                std.debug.print("Expected an error at the end of lexing:\n", .{});
                std.debug.print("  Expected error: {t}\n", .{expected_error});
                std.debug.print("  Got: {?}\n", .{t});
                return error.expected_error;
            };
            if (actual_error != expected_error) {
                std.debug.print("Expected a different error at the end of lexing:\n", .{});
                std.debug.print("  Expected error: {t}\n", .{expected_error});
                std.debug.print("  Got error: {t}\n", .{actual_error});
                return error.expected_different_error;
            }
        } else {
            const maybe_token: ?Token = lexer.next_token() catch |err| {
                std.debug.print("Expected an EOF, got error:\n", .{});
                std.debug.print("  Got error: {t}\n", .{err});
                return error.unexpected_error_instead_of_eof;
            };
            if (maybe_token) |t| {
                std.debug.print("Expected an EOF, got token:\n", .{});
                std.debug.print("  Got token: {t}\n", .{t.kind});
                return error.unexpected_token_instead_of_eof;
            }
        }
    }
};

test "lex simple characters" {
    // Indexes into the input string:
    //             012345
    const input = ".^()[]";

    const e = testing.e;
    try testing.test_lexer(input, &[_]testing.ExpectedToken{
        e(.dot, ".", 0),
        e(.exit, "^", 1),
        e(.open_parenthesis, "(", 2),
        e(.close_parenthesis, ")", 3),
        e(.open_bracket, "[", 4),
        e(.close_bracket, "]", 5),
    }, null);
}

test "lex the assign token" {
    // Indexes into the input string:
    //                         0123456789
    const input: []const u8 = " := . := ";

    const e = testing.e;
    try testing.test_lexer(input, &[_]testing.ExpectedToken{
        e(.assign, ":=", 1),
        e(.dot, ".", 4),
        e(.assign, ":=", 6),
    }, null);
}

test "lex text with comments" {
    const input: []const u8 =
        // Indexes into the input string:
        //          10        20        30        40        50        60
        //01234567890123456789012345678901234567890123456789012345678901234
        \\." This is some comment"^"Another comment"("""""""Final comment")
    ;

    const e = testing.e;
    try testing.test_lexer(input, &[_]testing.ExpectedToken{
        e(.dot, ".", 0),
        e(.exit, "^", 24),
        e(.open_parenthesis, "(", 42),
        e(.close_parenthesis, ")", 64),
    }, null);
}

test "lex text with whitespace and comments" {
    // Indexes into the input string:
    //                                       10         20        30         40         50        60
    //                         012 3 4 5678 90 12345678901234567890123  7 89 012 345678901234567890123 456
    const input: []const u8 = " .\n\"\"^^[\t \" Hi! this is a comment Ř \"  \n  \" Double comment! :D \" ] \" Also a comment at the end :)\"";

    const e = testing.e;
    try testing.test_lexer(input, &[_]testing.ExpectedToken{
        e(.dot, ".", 1),
        e(.exit, "^", 5),
        e(.exit, "^", 6),
        e(.open_bracket, "[", 7),
        e(.close_bracket, "]", 66),
    }, null);
}

test "should error on non-ascii character" {
    const input = "^^" ++ .{ 130, 150 };

    const e = testing.e;
    try testing.test_lexer(input, &[_]testing.ExpectedToken{
        e(.exit, "^", 0),
        e(.exit, "^", 1),
    }, Lexer.Error.non_ascii_byte);
}

test "lex identifiers" {
    // Indexes into the input string:
    //                                   10        20        30
    //                         01234567890123456789012345678901234
    const input: []const u8 = "Hello hoW_:  are :you _som9 :wrong: ";

    const e = testing.e;
    try testing.test_lexer(input, &[_]testing.ExpectedToken{
        e(.identifier, "Hello", 0),
        e(.keyword, "hoW_:", 6),
        e(.identifier, "are", 13),
        e(.block_param, ":you", 17),
        e(.identifier, "_som9", 22),
    }, Lexer.Error.colon_at_both_identifier_ends);
}

test "lex number" {
    // Indexes into the input string:
    //                                   10        20        30
    //                         01234567890123456789012345678901234
    const input: []const u8 = "  3  42  85769  2.0  9. 3.1415 5";

    const e = testing.e;
    try testing.test_lexer(input, &[_]testing.ExpectedToken{
        e(.integer, "3", 2),
        e(.integer, "42", 5),
        e(.integer, "85769", 9),
        e(.float, "2.0", 16),
        e(.integer, "9", 21),
        e(.dot, ".", 22),
        e(.float, "3.1415", 24),
        e(.integer, "5", 31),
    }, null);
}

test "lex negative number" {
    // Indexes into the input string:
    //                                   10        20        30
    //                         012345678901234567890123456789012345678
    const input: []const u8 = "  42  -5  -97  - 3  -253 -2.1  -43.472";

    const e = testing.e;
    try testing.test_lexer(input, &[_]testing.ExpectedToken{
        e(.integer, "42", 2),
        //
        e(.binary_selector, "-", 6),
        e(.integer, "5", 7),
        //
        e(.binary_selector, "-", 10),
        e(.integer, "97", 11),
        //
        e(.binary_selector, "-", 15),
        e(.integer, "3", 17),
        //
        e(.binary_selector, "-", 20),
        e(.integer, "253", 21),
        //
        e(.binary_selector, "-", 25),
        e(.float, "2.1", 26),
        //
        e(.binary_selector, "-", 31),
        e(.float, "43.472", 32),
    }, null);
}

test "lex empty string literal" {
    const input = "''";

    const e = testing.e;
    try testing.test_lexer(input, &[_]testing.ExpectedToken{
        e(.string_literal, "''", 0),
    }, null);
}

test "lex simple string literal" {
    // Indexes into the input string:
    //             012345
    const input = "'ahoj'";

    const e = testing.e;
    try testing.test_lexer(input, &[_]testing.ExpectedToken{
        e(.string_literal, "'ahoj'", 0),
    }, null);
}

test "lex multiple string literals" {
    // Indexes into the input string:
    //                       10        20
    //             0123456789012345678901234567
    const input = "  'Ahoj!' 'jak' 'se'  'mas?' ";

    const e = testing.e;
    try testing.test_lexer(input, &[_]testing.ExpectedToken{
        e(.string_literal, "'Ahoj!'", 2),
        e(.string_literal, "'jak'", 10),
        e(.string_literal, "'se'", 16),
        e(.string_literal, "'mas?'", 22),
    }, null);
}

test "lex a string literals with escape codes" {
    const input =
        // Indexes into the input string:
        //          10        20        30        40
        //01234567890123456789012345678901234567890123456789
        \\'Newline \n was here' 'or tab \t was also \t here'
    ;

    const e = testing.e;
    try testing.test_lexer(input, &[_]testing.ExpectedToken{
        e(.string_literal, "'Newline \\n was here'", 0),
        e(.string_literal, "'or tab \\t was also \\t here'", 22),
    }, null);
}

test "lex multiline string literal" {
    const input =
        // Indexes into the input string:
        //          10        20
        //0123456789012345678901234  5(for '\n')
        \\an_identifier 'First line

        //26  30
        //67890123456  7(for '\n')
        \\second line

        //  40
        //890123456789
        \\last line' an_identifier2
    ;

    const e = testing.e;
    try testing.test_lexer(input, &[_]testing.ExpectedToken{
        e(.identifier, "an_identifier", 0),
        e(.string_literal, "'First line\nsecond line\nlast line'", 14),
        e(.identifier, "an_identifier2", 49),
    }, null);
}

test "lex code" {
    // Indexes into the input string:
    //                       10        20        30        40
    //             01234567890123456789012345678901234567890123456789
    const input = "  SomeClass =( hi :D )  ";

    const e = testing.e;
    try testing.test_lexer(input, &[_]testing.ExpectedToken{
        e(.identifier, "SomeClass", 2),
        e(.binary_selector, "=", 12),
        e(.open_parenthesis, "(", 13),
        e(.identifier, "hi", 15),
        e(.block_param, ":D", 18),
        e(.close_parenthesis, ")", 21),
    }, null);
}

test "lex snapshot code" {
    // Indexes into the input string:
    //                       10        20        30        40
    //             01234567890123456789012345678901234567890123456789
    const input = "Example = ( )\n";

    const e = testing.e;
    try testing.test_lexer(input, &[_]testing.ExpectedToken{
        e(.identifier, "Example", 0),
        e(.binary_selector, "=", 8),
        e(.open_parenthesis, "(", 10),
        e(.close_parenthesis, ")", 12),
    }, null);
}

test "🤮 lex separators 🤮" {
    // Indexes into the input string:
    //                       10        20
    //             012345678901234567890123456
    const input = " - -- --- ---- ----- ------";

    const e = testing.e;
    try testing.test_lexer(input, &[_]testing.ExpectedToken{
        e(.binary_selector, "-", 1),
        e(.binary_selector, "--", 3),
        e(.binary_selector, "---", 6),
        e(.separator, "----", 10),
        e(.separator, "-----", 15),
        e(.separator, "------", 21),
    }, null);
}

pub fn print_tokens(
    input: []const u8,
    gpa: std.mem.Allocator,
    writer: *std.io.Writer,
    err_writer: *std.io.Writer,
) !void {
    var reporter = ErrorReporter{
        .writer = err_writer,
        .use_color = false,
        .source = input,
        .source_path = null,
    };
    var tokenized_file: TokenizedFile = tokenize(.{
        .allocator = gpa,
        .reporter = &reporter,
        .source_code = input,
        .source_code_filepath = null,
    }) catch |lex_error| {
        try err_writer.print("Failed with lexing error: '{t}'\n", .{lex_error});
        return;
    };
    defer tokenized_file.deinit(gpa);

    const maybe_span = tokenized_file.total_token_span();
    if (maybe_span == null) {
        try writer.print("(no tokens)\n", .{});
        return;
    }
    var iter = maybe_span.?.iter();

    var line_buffer: [4096]u8 = undefined;
    var line_writer: std.io.Writer = std.io.Writer.fixed(&line_buffer);

    try writer.print("Position   Token                      String (according to position of the token)\n", .{});
    while (iter.next()) |token_id| {
        const pos = tokenized_file.pos_of(token_id);
        const kind = tokenized_file.kind_of(token_id);
        const text = tokenized_file.text_at(token_id);
        try line_writer.print("[{d:3}..{d:3}] {t}", .{
            pos.start_idx,
            pos.end_idx_inclusive(),
            kind,
        });
        const line_so_far = line_buffer[0..line_writer.end];
        _ = line_writer.consumeAll();
        try writer.print("{s:<36}| \"{s}\"\n", .{
            line_so_far, text,
        });
    }
}

test "snapshot test on example files" {
    const snapshot_testing = @import("../snapshot_testing.zig");
    const opts = snapshot_testing.opts;
    if (opts.test_lexer_files_path.len == 0) return;
    try snapshot_testing.do_snapshot_tests(.{
        .snapshots_directory = opts.snapshots_path ++ "/lexer",
        .tested_files_directory = opts.test_lexer_files_path,
        .output_producer = print_tokens,
    }, "Lexing");
}
