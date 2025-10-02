/// @baka-src Heavily inspired by the `tokenizer.zig` in the standard library.
const std = @import("std");
const error_reporter = @import("reporter.zig");
const ErrorReporter: type = error_reporter.ErrorReporter;

const token = @import("token.zig");
const Token: type = token.Token;
const CodePosition: type = token.CodePosition;
const CodeSpan: type = token.CodeSpan;
const IntegerType: type = token.IntegerRepresentation;

const LexerError = error{
    unexpected_character,
    alone_colon,
    non_ascii_byte,
    invalid_lexer_state_encountered,
    number_literal_too_big,
};

const Lexer = struct {
    const Self = @This();
    current_char_idx: usize = 0,
    text: []u8,
    buffer_peeked_token: ?Token,
    reporter: ErrorReporter,

    /// Returning `null` means eof.
    fn peek_token(self: *Self) LexerError!?Token {
        if (self.buffer_peeked_token) |t| {
            return t;
        }
        self.buffer_peeked_token = null;
        self.buffer_peeked_token = try self.next_token();
        return self.buffer_peeked_token;
    }

    /// Returning `null` means eof.
    fn next_token(self: *Self) LexerError!?Token {
        if (self.buffer_peeked_token) |t| {
            self.buffer_peeked_token = null;
            return t;
        }

        const token_start_idx = self.current_char_idx;
        const peeked_char = try self.current_char() orelse return null;

        switch (peeked_char) {
            ':' => {
                self.current_char_idx += 1;
                switch (self.current_char()) {
                    '=' => {
                        self.char_iterator.eat_char();
                        return Token{
                            .position = CodePosition.at(token_start_idx),
                            .kind = .{.assign},
                        };
                    },
                    for (identifier_start_chars) |c| c => {
                        const token_end_idx = try self.lex_identifier(false);
                        const identifier = self.text[token_start_idx..token_end_idx];
                        return Token{
                            .position = CodePosition.from_start_and_end(token_start_idx, token_end_idx - 1),
                            .kind = .{ .block_param = identifier },
                        };
                    },
                    else => {
                        self.reporter.report_error(
                            .{ .pos = CodePosition.at(token_start_idx) },
                            "Found the ':' character on its own. Maybe it should be a part of some identifier?",
                            .{},
                        );
                        return LexerError.alone_colon;
                    },
                }
            },
            for (identifier_start_chars) |c| c => {
                const token_end_idx = try self.lex_identifier(true);
                const identifier = self.text[token_start_idx..token_end_idx];

                var kind = undefined;
                if (identifier[identifier.len - 1] == ':') {
                    kind = .{ .keyword_message = identifier };
                } else {
                    kind = .{ .identifier = identifier };
                }
                return Token{
                    .position = CodePosition.from_start_and_end(token_start_idx, token_end_idx - 1),
                    .kind = kind,
                };
            },
            '^' => {
                self.current_char_idx += 1;
                return Token{ .position = CodePosition.at(token_start_idx), .kind = .{.exit} };
            },
            '|' => {
                self.current_char_idx += 1;
                return Token{ .position = CodePosition.at(token_start_idx), .kind = .{.pipe} };
            },
            '.' => {
                self.current_char_idx += 1;
                return Token{ .position = CodePosition.at(token_start_idx), .kind = .{.dot} };
            },
            '(' => {
                self.current_char_idx += 1;
                return Token{ .position = CodePosition.at(token_start_idx), .kind = .{.open_parenthesis} };
            },
            ')' => {
                self.current_char_idx += 1;
                return Token{ .position = CodePosition.at(token_start_idx), .kind = .{.close_parenthesis} };
            },
            '[' => {
                self.current_char_idx += 1;
                return Token{ .position = CodePosition.at(token_start_idx), .kind = .{.open_bracket} };
            },
            ']' => {
                self.current_char_idx += 1;
                return Token{ .position = CodePosition.at(token_start_idx), .kind = .{.close_bracket} };
            },
            for (binary_message_chars) |c| c => {
                const token_end_idx = self.lex_binary_message();
                const identifier = self.text[token_start_idx..token_end_idx];
                const token_position = CodePosition.from_start_and_end(
                    token_start_idx,
                    token_start_idx - 1,
                );

                // Check if the lex'ed identifier could be the 'pipe' token
                if (identifier.len == 1 and identifier[0] == '|') {
                    return Token{ .pos = token_position, .kind = .{.pipe} };
                }

                // Check if the lex'ed identifier could be a negative sign in front of a number
                const current_char_is_digit = blk: {
                    const chr = try self.current_char() orelse break :blk false;
                    break :blk std.ascii.isDigit(chr);
                };
                if (identifier.len == 1 and identifier[0] == '-' and current_char_is_digit) {
                    //self.lex_number();
                    @panic("TODO: lex negative numbers :)");
                }

                // Check if the lex'ed identifier could be the 'separator' token
                const consists_only_of_dashes: bool = std.mem.allEqual(u8, identifier, '-');
                if (identifier.len >= separator_minimum_length and consists_only_of_dashes) {
                    return Token{ .pos = token_position, .kind = .{.separator} };
                }

                return Token{
                    .pos = token_position,
                    .kind = .{ .binary_message = identifier },
                };
            },
            for (digits) |d| d => {
                // TODO
                @panic("TODO: lexing of numbers is not implemented yet :)");
            },
            else => |chr| {
                self.reporter.report_error(
                    .{ .pos = CodePosition.at(token_start_idx) },
                    "Unexpected character: '{c}'",
                    chr,
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

    // TODO: lex_decimal_part_of_floating_point_number (what a horrible name xd)
    fn lex_integer(self: *Self, had_minus: bool) LexerError!i64 {
        const start_char = (try self.current_char()).?;
        std.debug.assert(std.mem.indexOfScalar(u8, digits, start_char) != null);
        var whole_part = start_char - '0';
        var did_overflow = false;

        self.current_char_idx += 1;

        loop: switch (try self.current_char()) {
            for (digits) |c| c => |c| {
                if (!did_overflow) {
                    const digit = c.? - '0';
                    whole_part = std.math.mul(IntegerType, whole_part, 10) catch blk: {
                        did_overflow = true;
                        break :blk 0;
                    };
                    whole_part = std.math.add(IntegerType, whole_part, digit) catch blk: {
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
                    return whole_part;
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
        std.debug.assert(std.mem.indexOfScalar(u8, binary_message_chars, (try self.current_char()).?) != null);
        self.current_char_idx += 1;

        loop: switch (try self.current_char()) {
            for (binary_message_chars) |c| c => {
                self.current_char_idx += 1;
                continue :loop try self.current_char();
            },
            else => {
                return self.current_char_idx;
            },
        }
    }

    /// Advances the lexer until it is no longer at a position that is part of an identifier.
    /// Crashes (via `unreachable`) if the starting position of the lexer is not at the beginning of an identifier.
    ///
    /// Returns the end character index of the identifier (excluding end index) - which is the new `current_char_idx`
    /// of the lexer.
    fn lex_identifier(self: *Self, can_have_colon_at_the_end: bool) LexerError!usize {
        std.debug.assert(std.mem.indexOfScalar(u8, identifier_start_chars, (try self.current_char()).?) != null);
        self.current_char_idx += 1;

        loop: switch (try self.current_char()) {
            for (identifier_chars) |c| c => {
                self.current_char_idx += 1;
                continue :loop try self.current_char();
            },
            else => |chr| {
                if (chr == ':' and can_have_colon_at_the_end) {
                    self.current_char_idx += 1;
                }
                return self.current_char_idx;
            },
        }
    }
};

const digits = "0123456789";

const binary_message_chars =
    \\&@,/=<-\>~|%+*
;

/// Valid identifier starting characters
const identifier_start_chars = std.ascii.letters + "_";

/// Valid characters in an identifier (not at the beginning of the identifier)
const identifier_chars = identifier_start_chars ++ digits;

const separator_minimum_length = 4;
