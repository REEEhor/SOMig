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
const ExpressionKind = ast_module.ExpressionKind;
const ClassDefinition = ast_module.ClassDefinition;
const ExprId = ast_module.ExprId;
const Identifier = ast_module.Identifier;
const MethodDefinition = ast_module.MethodDefinition;
const TokenSpan = ast_module.TokenSpan;
const KeywordArgumentPair = ast_module.KeywordArgumentPair;
const MethodBody = ast_module.MethodBody;
const MethodHeader = ast_module.MethodHeader;
const MethodHeaderKind = ast_module.MethodHeaderKind;

const reporter_module = @import("reporter.zig");
const ErrorReporter = reporter_module.ErrorReporter;
const debug_reporter = reporter_module.debug_reporter;

/// TODO: remove this once the location of AST nodes is supposed to be implemented.
/// You can use the compiler errors to find all usages of this.
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
    expressions_not_separated_by_dot,

    /// TODO: remove this once all features are supposed to be parsed. This is just for testing (so that the parser does not panic)
    TODO,
} || LexerError;
const TokenKindTag = std.meta.Tag(TokenKind);
const TokenId = usize;

pub const Parser = struct {
    const Self = @This();
    reporter: ErrorReporter,
    allocator: std.mem.Allocator,
    tokens: []Token,
    next_token_idx: TokenId,
    text: []const u8,

    /// List of expressions in the parsed program.
    /// Expressions use `ExprId` (an integer) to refer to their sub-expressions.
    /// This `ExprId` is an index into this array-list.
    expressions: std.ArrayList(Expression),

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
            .expressions = std.ArrayList(Expression).empty,
            .allocator = allocator,
            .tokens = tokens.items,
            .text = lexer.text,
            .next_token_idx = 0,
        };
    }

    pub fn parse(self: *Self) ParserError!ClassDefinition {
        const class_name: Identifier = self.text_at((try self.eat_token(.identifier)).pos.*);
        _ = try self.eat_binary_message("=");
        // TODO: parse a potential super class here
        _ = try self.eat_token(.open_parenthesis);
        // TODO: parse a potential instance fields here

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
            .span = todo_span,
        };

        _ = try self.eat_token(.close_parenthesis);

        return class_definition;
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
                _ = self.next_token();
                // TODO: parse locals
                return self.TODO("Parsing locals");

                // break :parse_locals locals;
            } else {
                break :parse_locals &[_]Identifier{};
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
                    break :get_expr try self.create_expression(todo_span, .{
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
            if (!saw_dot) if (expressions.getLastOrNull()) |prev_expr| {
                const end_of_prev_expr = self.pos_of(prev_expr).end_idx_inclusive();
                const error_pos = CodePosition.at(end_of_prev_expr);
                self.reporter.report_error(.{ .pos = error_pos }, "Expected a `.` after this expression.", .{});
                return ParserError.expressions_not_separated_by_dot;
            };

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
        const method_definition = MethodDefinition{
            .header = .{ .span = todo_span, .kind = .{ .unary = .{ .method_name = method_name } } },
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
        // TODO(cleanup): Maybe some sort of scratch temporary allocator could be used here?
        var keyword_arguments = std.ArrayList(KeywordArgumentPair).empty;

        // Parse keyword message calls
        while (self.peek_next_token()) |token| {
            if (token.tag() != .keyword_message) break;
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
                .keyword = self.text_at(token.pos),
            });
        }
        // We didn't parse any keyword pairs, so the resulting expression is not a keyword message call
        if (keyword_arguments.items.len == 0) return first_argument_id;

        const args: []KeywordArgumentPair = try keyword_arguments.toOwnedSlice(self.allocator);
        return self.create_expression(todo_span, ExpressionKind{ .keyword_message_call = .{
            .first_argument = first_argument_id,
            .args = args,
        } });
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
                .message = self.text_at(token.pos),
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
            result_expr_id = try self.create_expression(todo_span, .{ .unary_message_call = .{
                .argument = result_expr_id,
                .message = self.text_at(token.pos),
            } });
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
        assert(std.math.maxInt(ExprId) > self.expressions.items.len);

        const new_expression_id: ExprId = @truncate(self.expressions.items.len);
        try self.expressions.append(self.allocator, new_expression);
        return new_expression_id;
    }

    fn eat_binary_message(self: *Self, expected_contents: []const u8) ParserError!PayloadWithPos(.binary_message) {
        const binary_message = self.eat_token(.binary_message) catch |err| {
            if (err == ParserError.unexpected_token) {
                self.reporter.add_note(.no_location, "Expected binary message was \"{s}\"", .{expected_contents});
            }
            return err;
        };

        const actual_contents = self.text_at(binary_message.pos.*);
        if (std.mem.eql(u8, actual_contents, expected_contents)) {
            return binary_message;
        }

        return self.report_unexpected_token(binary_message.to_token(), .binary_message);
    }

    fn text_at(self: *Self, pos: CodePosition) []const u8 {
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
        if (self.next_token_idx >= self.tokens.len) {
            return null;
        }
        return &self.tokens[self.next_token_idx];
    }

    fn next_token(self: *Self) ?*Token {
        const token = self.peek_next_token();
        if (token != null) self.next_token_idx += 1;
        return token;
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
};

fn print_expression_recursive(
    writer: *std.io.Writer,
    formatter: SpanFormatter,
    expr_id: ExprId,
    expressions: []Expression,
    indent: i32,
) !void {
    const expression = expressions[expr_id];

    for (0..@intCast(indent)) |_| try writer.print("\t", .{});

    try writer.print("- {f}(id={d}) ", .{ formatter.fmt(expression.span), expr_id });
    switch (expression.kind) {
        .variable => |identifier| try writer.print("Variable({s})\n", .{identifier}),
        .integer_literal => |value| try writer.print("Integer literal({d})\n", .{value}),
        .float_literal => |value| try writer.print("Float literal({d})\n", .{value}),
        .string_literal => |value| try writer.print("String literal({s})\n", .{value}),

        .exit_expression => |exit| {
            try writer.print("Exit expression with return value:\n", .{});
            try print_expression_recursive(writer, formatter, exit.return_value, expressions, indent + 1);
        },
        .assignment => |assignment| {
            try writer.print("Assignment of '{s}' to:\n", .{assignment.variable});
            try print_expression_recursive(writer, formatter, assignment.target_value, expressions, indent + 1);
        },

        .unary_message_call => |unary_call| {
            try writer.print("Unary message '{s}' to the object:\n", .{unary_call.message});
            try print_expression_recursive(writer, formatter, unary_call.argument, expressions, indent + 1);
        },
        .binary_message_call => |binary_call| {
            try writer.print("Binary message call '{s}', with lhs:\n", .{binary_call.message});
            try print_expression_recursive(writer, formatter, binary_call.lhs, expressions, indent + 1);

            for (0..@intCast(indent)) |_| try writer.print("\t", .{});
            try writer.print("  and rhs:\n", .{});
            try print_expression_recursive(writer, formatter, binary_call.rhs, expressions, indent + 1);
        },
        .keyword_message_call => |keyword_call| {
            try writer.print("Keyword message call on object:\n", .{});
            try print_expression_recursive(writer, formatter, keyword_call.first_argument, expressions, indent + 1);

            for (0..@intCast(indent)) |_| try writer.print("\t", .{});
            try writer.print("  and argument pairs:\n", .{});

            for (keyword_call.args) |arg_pair| {
                for (0..@intCast(indent + 1)) |_| try writer.print("\t", .{});
                try writer.print("- Keyword '{s}' and arg:\n", .{arg_pair.keyword});
                try print_expression_recursive(writer, formatter, arg_pair.argument, expressions, indent + 2);
            }
        },
    }
}

pub fn print_tokens(
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
        span_formatter.fmt(class_definition.span), class_definition.class_name,
    });

    if (class_definition.instance_methods.len == 0) {
        try writer.print("\t(no methods)\n", .{});
    }

    for (class_definition.instance_methods, 1..) |method, method_idx| {
        try writer.print("{f}Method #{d}:\n", .{ span_formatter.fmt(method.span), method_idx });

        const header = method.header;
        try writer.print("\t{f}Header: ", .{span_formatter.fmt(header.span)});
        switch (header.kind) {
            .unary => |info| {
                try writer.print("(unary-method) '{s}'\n", .{info.method_name});
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
        if (method.body.locals.len != 0) {
            try writer.print("\t\tLocals:\n", .{});
        }
        for (method.body.locals, 1..) |local, idx| {
            try writer.print("\t\t\t#{d}: '{s}'", .{ idx, local });
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

            try print_expression_recursive(writer, span_formatter, expr, parser.expressions.items, indent);
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
        .output_producer = print_tokens,
    }, "Parsing");
}
