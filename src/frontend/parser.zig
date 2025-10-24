// @nice-to-have:
//  When there is an unexpected binary message, it might have been meant
//    as a unary operator. Nice error message would have been nice.
//  Maybe the lexer should lex `+2` correctly.

// NOTE:
//  Currently, assignments can only be at the beginning of an expression (which is adhering to the grammar).
//  But it would be nice-to-have the possibility to use it somewhere else.
//  On the other hand, it is possible when surrounded by parenthesis like this: `( var1 := expression )`,
//    so it does not matter and it forces a better program style.

const std = @import("std");
const assert = std.debug.assert;

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
const KeywordArgumentPair = ast_module.KeywordArgumentPair;

const ErrorReporter = @import("reporter.zig").ErrorReporter;

/// TODO: remove this once this is properly implemented
/// Use the compiler errors to find all usages of this.
const todo_span = TokenSpan{
    .start_idx = 0,
    .end_idx = 0,
};

const ParserError = error{
    unexpected_eof,
    unexpected_token,
    unmatched_parenthesis,
    unmatched_bracket,
    non_variable_used_as_lhs_of_expression,

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
            if (token.tag() == .identifier) {
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
                self.reporter.report_unexpected_eof("Expected body of a method or a closing parenthesis.", .{});
                return ParserError.unexpected_eof;
            };
            if (token.tag() == .pipe) {
                @panic("TODO: parse locals");
                // TODO: parse locals
                // break :parse_locals locals;
            } else {
                break :parse_locals []Identifier{};
            }
        };

        // TODO: move this into a separate function:
        //          parse_function_body(self: *Self) struct { ends_with_exit: bool, expressions: []ExprId }
        // TODO: don't forget that there are dots between expressions

        var start_idx_exit_expression: ?@FieldType(CodePosition, "start_idx") = null;
        while (true) {
            // @continue: Check if it is a `^` and figure out how/when to parse expressions (after `^` it is required, but where else?)
            const token = self.peek_next_token() orelse break;
            // token.tag()
            // if (act)
            _ = try self.parse_expression();
        }
        // TODO: don't forget to check for exit (token `^`)

        _ = try self.eat_token(.close_parenthesis);

        // TODO: construct and return `MethodDefinition` (`MethodBody` first)
    }

    fn parse_expression(self: *Self) ParserError!ExprId {
        const primary_expr_id = try self.parse_primary();
        const primary_expression = self.expressions.items[primary_expr_id];

        const token = self.peek_next_token() orelse return primary_expr_id;

        // Check whether this expression is an assignment or not
        if (token.tag() == .assign) {
            const lhs_identifier: Identifier = blk: switch (primary_expression.kind) {
                .variable => |identifier| break :blk identifier,
                else => {
                    self.reporter.report_error(
                        .{ .pos = self.pos_of(primary_expr_id) },
                        "Only a variable can be on the left hand side of an assignment.",
                        .{},
                    );
                    self.reporter.add_note(
                        .no_location,
                        "The expression recognised here is: {t}.",
                        .{primary_expression.kind},
                    );
                    return ParserError.non_variable_used_as_lhs_of_expression;
                },
            };
            _ = self.next_token(); // Consume the assignment operator token
            const rhs_expression_id = try self.parse_expression();

            return self.create_expression(
                todo_span,
                .{ .assignment = .{ .variable = lhs_identifier, .target_value = rhs_expression_id } },
            );
        }

        return try self.parse_maybe_messages(primary_expr_id);
    }

    fn parse_maybe_messages(self: *Self, primary_expr_id: ExprId) ParserError!ExprId {
        const first_argument_id = try self.parse_maybe_binary_messages(primary_expr_id);
        // @cleanup: Maybe some sort of scratch temporary allocator could be used here?
        var keyword_arguments = std.ArrayList(KeywordArgumentPair).empty;

        // Parse keyword message calls
        while (self.peek_next_token()) |token| {
            if (token.tag() != .keyword_message) break;
            _ = self.next_token();
            const error_str = "Because of this, an argument to this keyword message could have been parsed.";

            // Parse the argument of the message call
            const argument_primary_id: ExprId = self.parse_primary() catch |err| {
                self.reporter.add_note(.{ .pos = token.pos }, error_str, .{});
                return err;
            };
            const argument_id: ExprId = self.parse_maybe_binary_messages(argument_primary_id) catch |err| {
                self.reporter.add_note(.{ .pos = token.pos }, error_str, .{});
                return err;
            };
            // Append it to the list of keyword arguments
            try keyword_arguments.append(self.allocator, .{
                .argument = argument_id,
                .keyword = self.text_at(token.pos),
            });
        }
        // We didn't parse any keyword pairs, so the resulting expression is not a keyword message call
        if (keyword_arguments.items.len == 0) return first_argument_id;

        const args: []KeywordArgumentPair = try keyword_arguments.toOwnedSlice(self.allocator);
        const keyword_message_call = .{ .first_argument = first_argument_id, .args = args };
        return self.create_expression(todo_span, .{ .keyword_message_call = keyword_message_call });
    }

    fn parse_maybe_binary_messages(self: *Self, lhs_expr_id: ExprId) ParserError!ExprId {
        var result_expr_id = try self.parse_maybe_unary_messages(lhs_expr_id);

        while (self.peek_next_token()) |token| {
            if (token.tag() != .binary_message) break;
            _ = self.next_token();

            // Parse right hand side of the binary message call
            const rhs_primary: ExprId = self.parse_primary() catch |err| {
                self.reporter.add_note(
                    .{ .pos = token.pos },
                    "Because of this, a right hand side operand could not have been parsed for this binary message.",
                    .{},
                );
                return err;
            };
            const rhs_expr_id: ExprId = try self.parse_maybe_unary_messages(rhs_primary);

            const binary_call = ExpressionKind{ .binary_message_call = .{
                .lhs = result_expr_id,
                .message = self.text_at(token),
                .rhs = rhs_expr_id,
            } };
            result_expr_id = try self.create_expression(todo_span, binary_call);
        }
        return result_expr_id;
    }

    fn parse_maybe_unary_messages(self: *Self, primary_expr_id: ExprId) ParserError!ExprId {
        var result_expr_id = primary_expr_id;
        while (self.peek_next_token()) |token| {
            if (token.tag() != .identifier) break;
            _ = self.next_token();

            // Append the message call
            const unary_call = .{
                .argument = result_expr_id,
                .message = self.text_at(token.pos),
            };
            result_expr_id = try self.create_expression(todo_span, .{ .unary_message_call = unary_call });
        }
        return result_expr_id;
    }

    fn pos_of(self: *Self, expression_id: ExprId) CodePosition {
        return self.expressions.items[expression_id].span.to_pos(self.tokens);
    }

    fn parse_primary(self: *Self) ParserError!ExprId {
        // This function should be called only when we expect a primary
        const token = self.next_token() orelse {
            self.reporter.report_unexpected_eof("Expected an expression.", .{});
            return ParserError.unexpected_eof;
        };
        const expression_kind: ExpressionKind = get_expression: switch (token.kind) {
            .identifier => {
                const text = self.text_at(token.pos);
                break :get_expression .{ .variable = text };
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
                self.reporter.report_error(.{ .pos = token.pos }, "Unmatched parenthesis found. Expected an expression.", .{});
                return ParserError.unmatched_parenthesis;
            },
            .close_bracket => {
                self.reporter.report_error(.{ .pos = token.pos }, "Unmatched bracket found. Expected an expression.", .{});
                return ParserError.unmatched_bracket;
            },
            // List all the tokens so if there is a change to the list of token options, we catch it here
            .exit, .separator, .pipe, .dot, .assign, .binary_message, .keyword_message, .block_param => {
                self.reporter.report_error(.{ .pos = token.pos }, "Unexpected token: {any}. Expected an expression.", .{token});
                return ParserError.unexpected_token;
            },
        };

        return self.create_expression(todo_span, expression_kind);
    }

    fn create_expression(self: *Self, span: TokenSpan, kind: ExpressionKind) ParserError!ExprId {
        return self.add_expression(.{ .span = span, .kind = kind });
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
