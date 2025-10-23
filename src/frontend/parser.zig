// @nice-to-have: When there is an unexpected binary message, it might have been meant
//                as a unary operator. Nice error message would have been nice.
//                Maybe the lexer should lex `+2` correctly.

const std = @import("std");
const assert = std.debug.assert;
const activeTag = std.meta.activeTag;

const lexer_module = @import("lexer.zig");
const Lexer = lexer_module.Lexer;
const LexerError = lexer_module.LexerError;

const token_module = @import("token.zig");
const Token = token_module.Token;
const TokenKind = token_module.TokenKind;
const CodePosition = token_module.CodePosition;

const ast_module = @import("ast.zig");
const Expression = ast_module.Expression;
const ExpressionKind = ast_module.ExpressionKind;
const ClassDefinition = ast_module.ClassDefinition;
const ExprId = ast_module.ExprId;
const Identifier = ast_module.Identifier;
const MethodDefinition = ast_module.MethodDefinition;
const TokenSpan = ast_module.TokenSpan;

const ErrorReporter = @import("reporter.zig").ErrorReporter;

const ParserError = error{
    unexpected_eof,
    unexpected_token,
    unmatched_parenthesis,
    unmatched_bracket,

    /// TODO: remove this, this is just for testing (so that the parser does not panic)
    TODO,
} || LexerError;
const TokenKindTag = std.meta.Tag(TokenKind);
const TokenId = usize;

pub const Parser = struct {
    const Self = @This();
    reporter: ErrorReporter,
    allocator: *std.mem.Allocator,
    tokens: []Token,
    next_token_idx: TokenId,

    /// List of expressions in the parsed program.
    /// Expressions use `ExprId` (an integer) to refer to their sub-expressions.
    /// This `ExprId` is an index into this array-list.
    expressions: std.ArrayList(Expression),

    pub fn create(lexer: Lexer, error_reporter: ErrorReporter, allocator: *std.mem.Allocator) ParserError!Parser {
        // Lex all the tokens
        // @cleanup: Arbitrary choice. Empirically choose the length
        // @cleanup: If we end up lexing all tokens ahead of time, than it makes sense to remove `.peek_token(...)` from `Lexer`
        const assumed_number_of_tokens = lexer.text.len / 8;
        var tokens = try std.ArrayList(Token).initCapacity(allocator, assumed_number_of_tokens);
        while (try lexer.next_token()) |token| {
            try tokens.append(allocator.*, token);
        }

        return Parser{
            .reporter = error_reporter,
            .expressions = std.ArrayList(Expression).empty,
            .allocator = allocator,
            .tokens = tokens.items,
            .next_token_idx = 0,
        };
    }

    pub fn parse(self: *Self) ParserError!ClassDefinition {
        const identifier = try self.eat_token(.identifier);
        _ = identifier;
        _ = try self.eat_binary_message("=");
        // TODO: parse a potential super class here
        try self.eat_token(.open_parenthesis);
        // TODO: parse a potential struct fields here

        var method_definitions = std.ArrayList(MethodDefinition).empty;
        while (true) {
            const token = self.peek_next_token() orelse break;
            // TODO: parse binary methods and keyword methods
            if (activeTag(token.kind) == .identifier) {
                const method_definition = try self.parse_unary_method_definition();
                try method_definitions.append(self.allocator, method_definition);
            }
        }

        try self.eat_token(.close_parenthesis);
    }

    fn parse_unary_method_definition(self: *Self) ParserError!MethodDefinition {
        const identifier_pos = (try self.eat_token(.identifier)).pos;
        const method_name: []const u8 = self.text_at(identifier_pos.*);

        _ = try self.eat_binary_message("=");
        _ = try self.eat_token(.open_parenthesis);

        const locals: []Identifier = parse_locals: {
            const token = self.peek_next_token() orelse {
                self.reporter.report_unexpected_eof("Expected body of a method or a closing parenthesis", .{});
                return ParserError.unexpected_eof;
            };
            if (activeTag(token.kind) == .pipe) {
                @panic("TODO: parse locals");
                // TODO: parse locals
                // break :parse_locals locals;
            } else {
                break :parse_locals []Identifier{};
            }
        };

        // TODO: parse expressions
        // TODO: don't forget that there are dots between expressions
        _ = try self.parse_expression();
        // TODO: don't forget to check for exit (token `^`)

        _ = try self.eat_token(.close_parenthesis);

        // TODO: construct and return `MethodDefinition` (`MethodBody` first)
    }

    fn parse_expression(self: *Self) ParserError!ExprId {
        const assignment_vars = std.ArrayList(Identifier).empty;
        var is_first_iteration = true;
        while (true) : (is_first_iteration = true) {
            const token = self.peek_next_token() orelse {
                // This function should never be called when there is no tokens left.
                assert(!is_first_iteration);
                self.reporter.report_unexpected_eof("Expected the right hand side of the assignment (an expression).", .{});
                return ParserError.unexpected_eof;
            };
            switch (token.kind) {
                .identifier => {
                    // @cleanup: Maybe some sort of a scratch allocator should be used here?
                    try assignment_vars.append(self.allocator, self.text_at(token.pos));
                },
                else => break, // We stop iterating the moment we don't see an identifier
            }
            _ = self.next_token();

            const maybe_assign = self.peek_next_token() orelse {
                // TODO: HERE
                //      Think about if these scenarios are the only ones that can happen here (I think yes):
                //         case1:     method = ( var1 := var2 := var3 [EOF]
                //         case2:     method = ( var1                 [EOF]
                //
                //      .. so probably the only problem is the missing parenthesis (I think)
                //      .. so the `if` below is probably not needed and the `is_first_iteration` variable can be moved into the body of this `while`
                //
                // if (!is_first_iteration) {
                //     TODO
                //     self.reporter.report_unexpected_eof("Expected ", .{});
                // }
                //
                return ParserError.unexpected_eof;
            };

            // TODO: match `:=` or break
        }
        // NOTE: handle `assignment_vars` here

        const primary = try parse_primary(self);
        // TODO: there might be an assignment and multiple lhs
        @panic("TODO");
        // TODO: parse messages
    }

    fn parse_primary(self: *Self) ParserError!ExprId {
        // This function should be called only when we expect a primary
        const token = self.next_token() orelse unreachable;
        const expression_kind: ExpressionKind = get_expression: switch (token.kind) {
            .identifier => {
                // NOTE: this should be probably an invalid state, since the identifier should have already been
                // parsed in the function `parse_expression`, that calls this. For refactoring reasons, I am keeping this here.
                // @cleanup: It would be nice if this branch is actually marked unreachable
                const text = self.text_at(token.pos);
                break :get_expression .{ .variable = .{ .identifier = text } };
            },
            .integer => |value| {
                break :get_expression .{ .integer_literal = value };
            },
            .float => |value| {
                break :get_expression .{ .float_literal = value };
            },
            .string_literal => |value| {
                break :get_expression .{ .string_literal = value };
            },
            .array_literal_begin => {
                // TODO: parse array literals
                return ParserError.TODO;
            },
            .open_parenthesis => {
                const inner_expression: ExprId = try self.parse_expression();
                _ = try self.eat_token(.close_parenthesis);
                return inner_expression;
            },
            .open_bracket => {
                // TODO: parse blocks
                return ParserError.TODO;
            },
            .hashtag => {
                // TODO: parse symbols
                return ParserError.TODO;
            },

            .close_parenthesis => {
                self.reporter.report_error(.{ .pos = token.pos }, "Unmatched parenthesis.", .{});
                return ParserError.unmatched_parenthesis;
            },
            .close_bracket => {
                self.reporter.report_error(.{ .pos = token.pos }, "Unmatched bracket.", .{});
                return ParserError.unmatched_bracket;
            },
            // List all the tokens so if there is a change to the list of token options, we catch it here
            .exit, .separator, .pipe, .dot, .assign, .binary_message, .keyword_message, .block_param => {
                self.reporter.report_error(.{ .pos = token.pos }, "Unexpected token: {any}. Expected an expression.", .{token});
                return ParserError.unexpected_token;
            },
        };

        const expression = Expression{
            .pos = TokenSpan{ .start_idx = 0, .end_idx = 0 }, // TODO: proper position
            .kind = expression_kind,
        };
        const new_expression_id = try self.add_expression(expression);
        return new_expression_id;
    }

    fn add_expression(self: *Self, new_expression: Expression) ParserError!ExprId {
        const new_expression_id = self.expressions.items.len;
        try self.expressions.append(self.allocator, new_expression);
        return new_expression_id;
    }

    fn eat_binary_message(self: *Self, expected_contents: []const u8) ParserError!PayloadWithPos(.binary_message) {
        const binary_message = self.eat_token(.binary_message) catch |err| {
            if (err == ParserError.unexpected_token) {
                self.reporter.add_note(.no_location, "Expected binary message was \"{}\"", .{expected_contents});
            }
            return err;
        };

        const actual_contents = self.text_at(binary_message.pos);
        if (std.mem.eql(u8, actual_contents, expected_contents)) {
            return binary_message;
        }

        return self.report_unexpected_token(binary_message.to_token(), .binary_message);
    }

    fn text_at(self: *Self, pos: CodePosition) []const u8 {
        return pos.slice_from(self.lexer.text);
    }

    // @epic-zig: This is insane that this works
    fn PayloadWithPos(comptime tag: TokenKindTag) type {
        return struct {
            pos: *CodePosition,
            payload: *@FieldType(TokenKind, @tagName(tag)),
            pub fn to_token(self: *@This()) Token {
                return Token{
                    .pos = self.pos.*,
                    .kind = @unionInit(TokenKind, @tagName(tag), self.payload.*),
                };
            }
        };
    }
    fn assert_token(self: *Self, actual_token: Token, comptime expected_tag: TokenKindTag) ParserError!PayloadWithPos(expected_tag) {
        switch (actual_token.kind) {
            inline else => |*payload, actual_tag| {
                if (actual_tag != expected_tag) {
                    return self.report_unexpected_token(actual_token.*, expected_tag);
                }
                return .{ .pos = &actual_token.pos, .payload = payload };
            },
        }
        unreachable;
    }
    fn eat_token(self: *Self, comptime expected_tag: TokenKindTag) ParserError!PayloadWithPos(expected_tag) {
        const actual_token = (try self.next_token()) orelse {
            // @nice-to-have: convert the token tag into a more readable version with some conversion function (<- to do)
            self.reporter.report_unexpected_eof("Expected '{t}'", .{expected_tag});
            return ParserError.unexpected_eof;
        };
        return self.assert_token(actual_token, expected_tag);
    }

    fn report_unexpected_token(self: *Self, actual_token: Token, expected_tag: TokenKindTag) error{unexpected_token} {
        // @nice-to-have: convert the token tag into a more readable version with some conversion function (<- to do)
        self.reporter.report_error(
            .{ .pos = actual_token.pos },
            "Unexpected token: {any}. Expected token {t}",
            .{ actual_token, expected_tag },
        );
        return ParserError.unexpected_token;
    }

    fn peek_next_token(self: *Self) ?*Token {
        if (self.next_token_idx >= self.tokens.len) {
            return null;
        }
        return *self.tokens[self.next_token_idx];
    }

    fn next_token(self: *Self) ?*Token {
        const token = self.peek_token();
        if (token) self.next_token_idx += 1;
        return token;
    }
};
