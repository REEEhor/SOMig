// TODO:
//  Check if it is possible to have empty locals list like this:
//      method = ( || )
//  Because that means we have to check for `TokenKind{.binary_message}` that is `||`
//
// TODO(nice-to-have):
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

const dbg = @import("../debug/debug.zig").dbg;

const lexer_module = @import("lexer.zig");
const Lexer = lexer_module.Lexer;
const LexerError = lexer_module.LexerError;

const token_module = @import("token.zig");
const Token = token_module.Token;
const TokenKind = token_module.TokenKind;
const CodePosition = token_module.CodePosition;

const ast_module = @import("ast.zig");
const Expression = ast_module.Expression;
const ExpressionList = ast_module.ExpressionList;
const ClassDefinition = ast_module.ClassDefinition;
const ExprId = ast_module.ExprId;
const Identifier = ast_module.Identifier;
const MethodDefinition = ast_module.MethodDefinition;
const TokenSpan = ast_module.TokenSpan;
const KeywordArgumentPair = ast_module.KeywordArgumentPair;
const MethodBody = ast_module.MethodBody;
const MethodHeader = ast_module.MethodHeader;
const MethodHeaderKind = ast_module.MethodHeaderKind;
const TokenId = ast_module.TokenId;

const reporter_module = @import("reporter.zig");
const ErrorReporter = reporter_module.ErrorReporter;
const debug_reporter = reporter_module.debug_reporter;

/// TODO: remove this once the location of AST nodes is supposed to be implemented.
/// You can use the compiler errors to find all usages of this.
const todo_span = TokenSpan.create(0, 0);

const ParserError = error{
    unexpected_eof,
    unexpected_token,
    unmatched_parenthesis,
    unmatched_bracket,
    unmatched_pipe,
    non_variable_used_as_lhs_of_expression,
    expressions_not_separated_by_dot,

    /// TODO: remove this once all features are supposed to be parsed. This is just for testing (so that the parser does not panic)
    TODO,
} || LexerError;
const TokenKindTag = std.meta.Tag(TokenKind);

pub const Parser = struct {
    const Self = @This();
    reporter: ErrorReporter,
    allocator: std.mem.Allocator,
    tokens: []Token,
    next_token_id: TokenId,
    text: []const u8,

    /// List of expressions in the parsed program.
    /// Expressions use `ExprId` (an integer) to refer to their sub-expressions.
    /// This `ExprId` is an index into this array-list.
    expressions: ExpressionList,

    pub fn create(lexer: *Lexer, error_reporter: ErrorReporter, allocator: std.mem.Allocator) ParserError!Parser {
        // Lex all the tokens
        // TODO(cleanup): Arbitrary choice. Empirically choose the length
        // TODO(cleanup): If we end up lexing all tokens ahead of time, than it makes sense to remove `.peek_token(...)` from `Lexer`
        const assumed_number_of_tokens = lexer.text.len / 8;
        var tokens = try std.ArrayList(Token).initCapacity(allocator, assumed_number_of_tokens);
        while (try lexer.next_token()) |token| {
            try tokens.append(allocator, token);
        }

        return Parser{
            .reporter = error_reporter,
            .expressions = ExpressionList{ .expressions = .empty },
            .allocator = allocator,
            .tokens = tokens.items,
            .text = lexer.text,
            .next_token_id = TokenId.create(0),
        };
    }

    pub fn parse(self: *Self) ParserError!ClassDefinition {
        const class_name: TokenId = self.next_token_id;
        _ = try self.eat_token(.identifier);
        _ = try self.eat_binary_message("=");
        // TODO: parse a potential super class here
        _ = try self.eat_token(.open_parenthesis);

        // Check if there could be instance fields
        // We have to check if the current character is a symbol *and* if it is not a definition of a field.
        // We can do that by checking if the token is or is not an equal sign.
        // For more info, see "pipe_as_binary_message.som" in the snapshot tests.
        var instance_fields: ?TokenSpan = null;
        if (self.peek_next_token()) |token_1| if (self.peek_token_at_offset(2)) |token_2| {
            const token_2_text = self.text_at_pos(token_2.pos);
            const is_token_2_equal_sign: bool = std.mem.eql(u8, "=", token_2_text);

            if (token_1.tag() == .pipe and !is_token_2_equal_sign) {
                instance_fields = try self.parse_locals("instance fields");
            }
        };

        var method_definitions = std.ArrayList(MethodDefinition).empty;
        while (self.peek_next_token()) |token| {
            // TODO: parse binary methods and keyword methods
            if (token.tag() == .identifier) {
                const method_definition = try self.parse_unary_method_definition();
                try method_definitions.append(self.allocator, method_definition);
            } else break;
        }

        const class_definition = ClassDefinition{
            .class_name = class_name,
            .instance_methods = try method_definitions.toOwnedSlice(self.allocator),
            .instance_fields = instance_fields,
            .span = todo_span,
        };

        _ = try self.eat_token(.close_parenthesis);

        return class_definition;
    }

    /// Parses:
    /// ```som
    ///     | var1 var2 var3  ...  varN |
    ///     ^
    ///  expected `self.next_token_idx`
    /// ```
    ///
    /// Argument `structure_name` is for error reporting.
    /// Probably one of "instance fields", "class fields", "locals of a method", "locals of a block".
    ///
    fn parse_locals(self: *Self, comptime structure_name: []const u8) ParserError!?TokenSpan {
        // Consume the pipe token
        const start_pos = (try self.eat_token(.pipe)).pos;
        const first_var_token_idx = self.next_token_id.idx;

        while (true) {
            const token = self.peek_next_token() orelse {
                self.reporter.report_unexpected_eof("Expected `|` to close the list of " ++ structure_name ++ ".", .{});
                self.reporter.add_note(.{ .pos = start_pos.* }, "The list of " ++ structure_name ++ " starts here.", .{});
                return ParserError.unmatched_pipe;
            };
            switch (token.kind) {
                .identifier => _ = self.next_token(),
                .pipe => {
                    _ = self.next_token();
                    break;
                },
                else => {
                    self.reporter.report_error(.{ .pos = token.pos }, "Unexpected token: {any}. Expected either a `|` or an identifier.", .{token.kind});
                    return ParserError.unmatched_pipe;
                },
            }
        }

        // After the `while` loop, the `self.next_token_idx` is pointing here:
        //      | var1 var2 ... varN | someOtherToken
        //                             ~~~~~~~~~~~~~~
        // So we need to subtract -1 to get to the end pipe symbol and -2 to get to the `varN`
        const last_var_token_idx = self.next_token_id.idx - 2;

        return TokenSpan.create_or_null(first_var_token_idx, last_var_token_idx);
    }

    fn parse_unary_method_definition(self: *Self) ParserError!MethodDefinition {
        const method_name: TokenId = self.next_token_id;
        _ = try self.eat_token(.identifier);

        _ = try self.eat_binary_message("=");
        _ = try self.eat_token(.open_parenthesis);

        const locals: ?TokenSpan = parse_locals: {
            const token = self.peek_next_token() orelse {
                self.reporter.report_unexpected_eof("Expected body of a method or a closing parenthesis.", .{});
                return ParserError.unexpected_eof;
            };
            if (token.tag() == .pipe) {
                _ = self.next_token();
                break :parse_locals try self.parse_locals("locals of a method");
            } else {
                break :parse_locals null;
            }
        };

        // TODO: move this into a separate function:
        //          parse_function_body(self: *Self) struct { ends_with_exit: bool, expressions: []ExprId }
        // TODO: don't forget that there are dots between expressions

        var expressions = std.ArrayList(ExprId).empty;
        var saw_dot = false;
        while (self.peek_next_token()) |token| {
            const expr_id: ExprId = get_expr: switch (token.kind) {
                .exit => {
                    _ = self.next_token(); // Consume the exit token
                    const return_value: ExprId = self.parse_expression() catch |err| {
                        self.reporter.add_note(.{ .pos = token.pos }, "An expression is expected because of an exit token here.", .{});
                        return err;
                    };
                    break :get_expr try self.add_expression(.{
                        .exit_expression = .{ .return_value = return_value },
                    });
                },
                .close_parenthesis, .close_bracket => {
                    break;
                },
                else => {
                    break :get_expr try self.parse_expression();
                },
            };
            // If this is not the first expression, there should have been a dot token before it.
            if (!saw_dot) if (expressions.getLastOrNull()) |prev_expr| {
                const end_of_prev_expr = self.pos_of(prev_expr).end_idx_inclusive();
                const error_pos = CodePosition.at(end_of_prev_expr);
                self.reporter.report_error(.{ .pos = error_pos }, "Expected a `.` after this expression.", .{});
                return ParserError.expressions_not_separated_by_dot;
            };

            // Skip all dot tokens. Set `saw_dot` to true.
            try expressions.append(self.allocator, expr_id);
            while (self.peek_next_token()) |maybe_dot| {
                if (maybe_dot.tag() != .dot) break;
                saw_dot = true;
                _ = self.next_token();
            } else saw_dot = false;
        }

        // TODO: when refactoring this, don't forget about blocks that end with `]`
        _ = try self.eat_token(.close_parenthesis);

        const method_body = MethodBody{
            .expressions = try expressions.toOwnedSlice(self.allocator),
            .locals = locals,
            .span = todo_span,
        };
        const header = MethodHeader{ .unary = .{ .method_name = method_name } };
        const method_definition = MethodDefinition{
            .header = header,
            .body = method_body,
            .span = todo_span,
        };
        return method_definition;
    }

    fn TODO(self: *Self, comptime fmt: []const u8) ParserError {
        self.reporter.report_error(.no_location, "TODO: " ++ fmt, .{});
        return ParserError.TODO;
    }

    fn parse_expression(self: *Self) ParserError!ExprId {
        const primary_expr_id: ExprId = try self.parse_primary();
        const primary_expression = self.expressions.at(primary_expr_id);

        const token = self.peek_next_token() orelse return primary_expr_id;

        // Check whether this expression is an assignment or not
        if (token.tag() == .assign) {
            const lhs_identifier: TokenId = blk: switch (primary_expression.*) {
                .variable => |token_id| break :blk token_id,
                else => {
                    self.reporter.report_error(
                        .{ .pos = self.pos_of(primary_expr_id) },
                        "Only a variable can be on the left hand side of an assignment.",
                        .{},
                    );
                    self.reporter.add_note(
                        .no_location,
                        "The expression recognised here is: {t}.",
                        .{primary_expression.*},
                    );
                    return ParserError.non_variable_used_as_lhs_of_expression;
                },
            };
            _ = self.next_token(); // Consume the assignment operator token
            const rhs_expression_id = try self.parse_expression();

            return self.add_expression(.{ .assignment = .{
                .variable = lhs_identifier,
                .target_value = rhs_expression_id,
            } });
        }

        return try self.parse_maybe_messages(primary_expr_id);
    }

    fn parse_maybe_messages(self: *Self, primary_expr_id: ExprId) ParserError!ExprId {
        const first_argument_id = try self.parse_maybe_binary_messages(primary_expr_id);
        // TODO(cleanup): Maybe some sort of scratch temporary allocator could be used here?
        var keyword_arguments = std.ArrayList(KeywordArgumentPair).empty;

        // Parse keyword message calls
        while (self.peek_next_token()) |token| {
            if (token.tag() != .keyword_message) break;
            const keyword_token_idx = self.next_token_id;
            _ = self.next_token();
            const error_str = "Because of this, an argument to this keyword message could have not been parsed.";

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
                .keyword = keyword_token_idx,
            });
        }
        // We didn't parse any keyword pairs, so the resulting expression is not a keyword message call
        if (keyword_arguments.items.len == 0) return first_argument_id;

        const args: []KeywordArgumentPair = try keyword_arguments.toOwnedSlice(self.allocator);
        const expression = Expression{ .keyword_message_call = .{
            .first_argument = first_argument_id,
            .args = args,
        } };
        return try self.add_expression(expression);
    }

    fn parse_maybe_binary_messages(self: *Self, lhs_expr_id: ExprId) ParserError!ExprId {
        var result_expr_id: ExprId = try self.parse_maybe_unary_messages(lhs_expr_id);

        while (self.peek_next_token()) |message_token| {
            if (message_token.tag() != .binary_message) break;
            const message_token_id = self.next_token_id;
            _ = self.next_token();

            // Parse right hand side of the binary message call
            const rhs_primary: ExprId = self.parse_primary() catch |err| {
                self.reporter.add_note(
                    .{ .pos = message_token.pos },
                    "Because of this, a right hand side operand could not have been parsed for this binary message.",
                    .{},
                );
                return err;
            };
            const rhs_expr_id: ExprId = try self.parse_maybe_unary_messages(rhs_primary);

            const binary_call = Expression{ .binary_message_call = .{
                .lhs = result_expr_id,
                .message = message_token_id,
                .rhs = rhs_expr_id,
            } };
            result_expr_id = try self.add_expression(binary_call);
        }
        return result_expr_id;
    }

    fn parse_maybe_unary_messages(self: *Self, primary_expr_id: ExprId) ParserError!ExprId {
        var result_expr_id = primary_expr_id;
        while (self.peek_next_token()) |unary_message_name| {
            if (unary_message_name.tag() != .identifier) break;
            const unary_message_name_id = self.next_token_id;
            _ = self.next_token();

            // Append the message call
            result_expr_id = try self.add_expression(.{ .unary_message_call = .{
                .argument = result_expr_id,
                .message = unary_message_name_id,
            } });
        }
        return result_expr_id;
    }

    fn pos_of(self: *Self, expression_id: ExprId) CodePosition {
        return self.expressions.at(expression_id).span(self.expressions).to_pos(self.tokens);
    }

    fn parse_primary(self: *Self) ParserError!ExprId {
        // This function should be called only when we expect a primary
        const token_id = self.next_token_id;
        const token = self.next_token() orelse {
            self.reporter.report_unexpected_eof("Expected an expression.", .{});
            return ParserError.unexpected_eof;
        };
        const expression: Expression = get_expression: switch (token.kind) {
            .identifier => {
                break :get_expression .{ .variable = token_id };
            },
            .integer => {
                break :get_expression .{ .integer_literal = token_id };
            },
            .float => {
                break :get_expression .{ .float_literal = token_id };
            },
            .string_literal => {
                break :get_expression .{ .string_literal = token_id };
            },
            .array_literal_begin => {
                // TODO: parse array literals
                return self.TODO("parse array literals");
            },
            .open_parenthesis => {
                const inner_expression: ExprId = try self.parse_expression();
                _ = try self.eat_token(.close_parenthesis);
                return inner_expression;
            },
            .open_bracket => {
                // TODO: parse blocks
                return self.TODO("parse blocks");
            },
            .hashtag => {
                // TODO: parse symbols
                return self.TODO("parse symbols");
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
                self.reporter.report_error(.{ .pos = token.pos }, "Unexpected token: {t}. Expected an expression.", .{token.tag()});
                return ParserError.unexpected_token;
            },
        };

        return self.add_expression(expression);
    }

    fn add_expression(self: *Self, new_expression: Expression) ParserError!ExprId {
        assert(std.math.maxInt(@FieldType(ExprId, "idx")) > self.expressions.len());

        const new_expression_idx = self.expressions.len();
        try self.expressions.expressions.append(self.allocator, new_expression);
        return ExprId{ .idx = @truncate(new_expression_idx) };
    }

    fn eat_binary_message(self: *Self, expected_contents: []const u8) ParserError!PayloadWithPos(.binary_message) {
        const binary_message = self.eat_token(.binary_message) catch |err| {
            if (err == ParserError.unexpected_token) {
                self.reporter.add_note(.no_location, "Expected binary message was \"{s}\"", .{expected_contents});
            }
            return err;
        };

        const actual_contents = self.text_at_pos(binary_message.pos.*);
        if (std.mem.eql(u8, actual_contents, expected_contents)) {
            return binary_message;
        }

        return self.report_unexpected_token(binary_message.to_token(), .binary_message);
    }

    fn text_at(self: *Self, token_id: TokenId) []const u8 {
        const pos = self.tokens[token_id.idx].pos;
        return self.text_at_pos(pos);
    }

    fn text_at_pos(self: *Self, pos: CodePosition) []const u8 {
        return pos.slice_from(self.text);
    }

    // NOTE(epic-zig): Nice compile time checked return value
    fn PayloadWithPos(comptime tag: TokenKindTag) type {
        return struct {
            pos: *const CodePosition,
            payload: *const @FieldType(TokenKind, @tagName(tag)),
            pub fn to_token(self: *const @This()) Token {
                return Token{
                    .pos = self.pos.*,
                    .kind = @unionInit(TokenKind, @tagName(tag), self.payload.*),
                };
            }
        };
    }
    fn assert_token(self: *Self, actual_token: *Token, comptime expected_tag: TokenKindTag) ParserError!PayloadWithPos(expected_tag) {
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
        const actual_token = self.next_token() orelse {
            // TODO(nice-to-have): convert the token tag into a more readable version with some conversion function (<- to do)
            self.reporter.report_unexpected_eof("Expected '{t}'", .{expected_tag});
            return ParserError.unexpected_eof;
        };
        return self.assert_token(actual_token, expected_tag);
    }

    fn token_payload(self: *Self, id: TokenId, comptime token_tag: TokenKindTag) PayloadWithPos(token_tag) {
        const token: *Token = &self.tokens[id.idx];

        switch (token.kind) {
            inline else => |*payload, tag| {
                if (tag == token_tag) {
                    return PayloadWithPos(token_tag){
                        .payload = payload,
                        .pos = &token.pos,
                    };
                } else unreachable;
            },
        }
    }

    fn report_unexpected_token(self: *Self, actual_token: Token, expected_tag: TokenKindTag) ParserError {
        // TODO(nice-to-have): convert the token tag into a more readable version with some conversion function (<- to do)
        self.reporter.report_error(
            .{ .pos = actual_token.pos },
            "Unexpected token: {any}. Expected token {t}",
            .{ actual_token, expected_tag },
        );
        return ParserError.unexpected_token;
    }

    fn peek_next_token(self: *Self) ?*Token {
        if (@as(usize, self.next_token_id.idx) >= self.tokens.len) {
            return null;
        }
        return &self.tokens[self.next_token_id.idx];
    }

    fn next_token(self: *Self) ?*Token {
        const token = self.peek_next_token();
        if (token != null) self.next_token_id.idx += 1;
        return token;
    }

    fn peek_token_at_offset(self: *Self, offset: i32) ?*Token {
        if (self.next_token_id.idx < offset) return null;
        const idx = self.next_token_id.idx + @abs(std.math.sign(offset) * offset);
        if (idx >= self.tokens.len) return null;
        return &self.tokens[idx];
    }
};

const SpanFormatter = struct {
    tokens: []Token,
    const Fmt = struct {
        tokens: []Token,
        span: TokenSpan,

        pub fn format(self: *const @This(), w: *std.io.Writer) std.io.Writer.Error!void {
            const pos = self.span.to_pos(self.tokens);
            try w.print("[{d:3}..{d:3}]", .{ pos.start_idx, pos.end_idx_inclusive() });
        }
    };

    pub fn fmt(self: *const @This(), span: TokenSpan) Fmt {
        return .{ .span = span, .tokens = self.tokens };
    }

    pub fn fmt_token(self: *const @This(), token: TokenId) Fmt {
        return .{ .span = TokenSpan.at(token), .tokens = self.tokens };
    }
};

fn print_expression_recursive(
    writer: *std.io.Writer,
    formatter: SpanFormatter,
    expr_id: ExprId,
    parser: *Parser,
    indent: i32,
) !void {
    const expression = parser.expressions.at(expr_id);

    for (0..@intCast(indent)) |_| try writer.print("\t", .{});

    try writer.print("- {f}(id={d}) ", .{
        formatter.fmt(expression.span(parser.expressions)),
        expr_id.idx,
    });
    switch (expression.*) {
        .variable => |identifier| try writer.print("Variable({s})\n", .{parser.text_at(identifier)}),
        .integer_literal => |token_id| {
            const value = parser.token_payload(token_id, .integer).payload.*;
            try writer.print("Integer literal({d})\n", .{value});
        },
        .float_literal => |token_id| {
            const value = parser.token_payload(token_id, .float).payload.*;
            try writer.print("Float literal({d})\n", .{value});
        },
        .string_literal => |token_id| {
            const value = parser.token_payload(token_id, .string_literal).payload.*;
            try writer.print("String literal({s})\n", .{value});
        },

        .exit_expression => |exit| {
            try writer.print("Exit expression with return value:\n", .{});
            try print_expression_recursive(writer, formatter, exit.return_value, parser, indent + 1);
        },
        .assignment => |assignment| {
            try writer.print("Assignment of '{s}' to:\n", .{parser.text_at(assignment.variable)});
            try print_expression_recursive(writer, formatter, assignment.target_value, parser, indent + 1);
        },

        .unary_message_call => |unary_call| {
            try writer.print("Unary message '{s}' to the object:\n", .{parser.text_at(unary_call.message)});
            try print_expression_recursive(writer, formatter, unary_call.argument, parser, indent + 1);
        },
        .binary_message_call => |binary_call| {
            try writer.print("Binary message call '{s}', with lhs:\n", .{parser.text_at(binary_call.message)});
            try print_expression_recursive(writer, formatter, binary_call.lhs, parser, indent + 1);

            for (0..@intCast(indent)) |_| try writer.print("\t", .{});
            try writer.print("  and rhs:\n", .{});
            try print_expression_recursive(writer, formatter, binary_call.rhs, parser, indent + 1);
        },
        .keyword_message_call => |keyword_call| {
            try writer.print("Keyword message call on object:\n", .{});
            try print_expression_recursive(writer, formatter, keyword_call.first_argument, parser, indent + 1);

            for (0..@intCast(indent)) |_| try writer.print("\t", .{});
            try writer.print("  and argument pairs:\n", .{});

            for (keyword_call.args) |arg_pair| {
                for (0..@intCast(indent + 1)) |_| try writer.print("\t", .{});
                try writer.print("- Keyword '{s}' and arg:\n", .{parser.text_at(arg_pair.keyword)});
                try print_expression_recursive(writer, formatter, arg_pair.argument, parser, indent + 2);
            }
        },
    }
}

pub fn print_class_definition(
    input: []const u8,
    gpa: std.mem.Allocator,
    writer: *std.io.Writer,
    err_writer: *std.io.Writer,
) !void {
    const StringLiteralsManager = @import("string_literals_manager.zig").StringLiteralsManager;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    var string_literals_manager = try StringLiteralsManager.create(allocator, allocator, 0);
    var lexer = Lexer.create(input, ErrorReporter{ .writer = err_writer }, &string_literals_manager);

    var parser = Parser.create(&lexer, ErrorReporter{ .writer = err_writer }, allocator) catch |init_error| {
        try err_writer.print("Failed with parser init error (probably lexing error): '{t}'\n", .{init_error});
        return;
    };
    const class_definition = parser.parse() catch |parse_error| {
        try err_writer.print("Failed with parse error: '{t}'\n", .{parse_error});
        return;
    };

    const span_formatter = SpanFormatter{ .tokens = parser.tokens };

    try writer.print("AST of the class {f}'{s}'\n", .{
        span_formatter.fmt(class_definition.span), parser.text_at(class_definition.class_name),
    });

    if (class_definition.instance_fields) |span_fields| {
        try writer.print("\tInstance fields:\n", .{});
        var iter = span_fields.iter();
        while (iter.next()) |token_id| {
            assert(parser.tokens[token_id.idx].tag() == .identifier);
            const text = parser.text_at(token_id);
            try writer.print("\t\t- '{s}'\n", .{text});
        }
    } else {
        try writer.print("\t(no instance fields)\n", .{});
    }

    if (class_definition.instance_methods.len == 0) {
        try writer.print("\t(no methods)\n", .{});
    }

    for (class_definition.instance_methods, 1..) |method, method_idx| {
        try writer.print("{f}Method #{d}:\n", .{ span_formatter.fmt(method.span), method_idx });

        const header = method.header;
        try writer.print("\t{f}Header: ", .{span_formatter.fmt(header.span())});
        switch (header) {
            .unary => |info| {
                try writer.print("(unary-method) '{s}'\n", .{parser.text_at(info.method_name)});
            },
            .binary => |info| {
                _ = info;
                return ParserError.TODO;
            },
            .keyword => |info| {
                _ = info;
                return ParserError.TODO;
            },
        }

        try writer.print("\t{f}Body:\n", .{span_formatter.fmt(method.body.span)});
        if (method.body.locals) |span_locals| {
            try writer.print("\t\tLocals:\n", .{});
            var iter = span_locals.iter();
            var idx: usize = 1;
            while (iter.next()) |token_id| : (idx += 1) {
                assert(parser.tokens[token_id.idx].tag() == .identifier);
                const local = parser.text_at(token_id);
                try writer.print("\t\t\t#{d}: '{s}'", .{ idx, local });
            }
        } else {
            try writer.print("\t\t(no locals)\n", .{});
        }
        const expressions = method.body.expressions;
        if (expressions.len != 0) {
            try writer.print("\t\tExpressions:\n", .{});
        } else {
            try writer.print("\t\t(no expressions)\n", .{});
        }
        for (expressions, 1..) |expr, idx| {
            try writer.print("\t\t\tExpression #{d}:\n", .{idx});
            const indent = 4; // because we want at least 4 tabulators before each expression

            try print_expression_recursive(writer, span_formatter, expr, &parser, indent);
        }
    }
}

test "snapshot test on example files" {
    const snapshot_testing = @import("snapshot_testing.zig");
    // TODO: check if the path is not empty to ignore the test
    const opts = snapshot_testing.opts;
    try snapshot_testing.do_snapshot_tests(.{
        .snapshots_directory = opts.snapshots_path ++ "/parser",
        .tested_files_directory = opts.test_files_path,
        .output_producer = print_class_definition,
    }, "Parsing");
}
