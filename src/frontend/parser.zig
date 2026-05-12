//! FIXME: Parse block parameters from multiple tokens, so that `:param` becomes `.{ .colon, .identifier }` and not `.{ .block_parameter }`.
//!         To do this, we have to:
//!             1. Remove `TokenKind.block_parameter`
//!             2. Change parser to accomodate this change
//!             3. Change AST expression for block parameters. Right now, we rely on parameters being a single token each.
//!

const std = @import("std");
const assert = std.debug.assert;

const debug_module = @import("../debug/debug.zig");
const dbg = debug_module.dbg;
const dbg_nl = debug_module.dbg_nl;
const dbgx = debug_module.dbgx;

const lexer_module = @import("lexer.zig");
const Lexer = lexer_module.Lexer;
const LexerError = lexer_module.Lexer.Error;

const token_module = @import("token.zig");
const can_be_separator = token_module.can_be_separator;
const is_pipe = token_module.is_pipe;
const Token = token_module.Token;
const TokenKind = token_module.TokenKind;
const CodePosition = token_module.CodePosition;
const TokenizedFile = token_module.TokenizedFile;

const ast_module = @import("ast.zig");
const Expression = ast_module.Expression;
const ExpressionList = ast_module.ExpressionList;
const Extras = ast_module.Extras;
const ClassAst = ast_module.ClassAst;
const ExprId = ast_module.ExprId;
const MethodAst = ast_module.MethodAst;
const TokenSpan = ast_module.TokenSpan;
const FunctionBody = ast_module.FunctionBody;
const FunctionBodyId = ast_module.FunctionBodyId;
const MethodHeader = ast_module.MethodHeader;
const TokenId = ast_module.TokenId;
const ArrayLiteral = ast_module.ArrayLiteral;
const ClassAstPortion = ast_module.ClassAstPortion;
const KeywordMethodHeader = ast_module.KeywordMethodHeader;
const BlockLiteral = ast_module.BlockLiteral;
const RawBinaryMessageSend = ast_module.RawBinaryMessageSend;
const BinaryMessageSend = ast_module.BinaryMessageSend;
const KeywordMessage = ast_module.KeywordMessage;
const KeywordMessageArgs = ast_module.KeywordMessageArgs;
const ExprSpanId = ast_module.ExprSpanId;
const FixedExprSpanId = ast_module.FixedExprSpanId;
const SpannedExpr = ast_module.SpannedExpr;
const Spanned = ast_module.Spanned;
const ParsedFile = ast_module.ParsedFile;

const reporter_module = @import("reporter.zig");
const ErrorReporter = reporter_module.ErrorReporter;
const debug_reporter = reporter_module.debug_reporter;

const ParserError = error{
    unexpected_eof,
    unexpected_token,
    unmatched_parenthesis,
    unmatched_bracket,
    unmatched_pipe,
    non_variable_used_as_lhs_of_expression,
    expressions_not_separated_by_dot,
    alone_hashtag,

    /// FIXME: remove this once all features are supposed to be parsed. This is just for testing (so that the parser does not panic)
    TODO,
} || LexerError || std.mem.Allocator.Error;

///
/// Example usage:
/// ```zig
///     var parser = Parser.create(...);
///     const ast: ParsedFile = try parser.parse();
/// ```
///
pub const Parser = struct {
    const Self = @This();
    reporter: *ErrorReporter,
    allocator: std.mem.Allocator,
    next_token_id: TokenId,

    ///
    /// Abstract syntax tree that is at the output of the `parse` method.
    ///
    /// After a parser is created, not all fields of `ast: ParsedFile` are initialised.
    /// During parsing, this field gets filled up with parsed expression and only
    /// after parsing, this field can be considered immutable and fully initialised.
    ast: ParsedFile,

    pub fn create(tokenized_input: TokenizedFile, error_reporter: *ErrorReporter, allocator: std.mem.Allocator) Parser {
        const ast = ParsedFile{
            .class_ast = undefined,
            .expressions = ExpressionList.empty,
            .extras = Extras.empty,
            .source_code = tokenized_input.source_code,
            .source_code_filepath = tokenized_input.source_code_filepath,
            .tokens = tokenized_input.tokens,
        };

        return Parser{
            .reporter = error_reporter,
            .allocator = allocator,
            .next_token_id = TokenId.create(0),
            .ast = ast,
        };
    }

    pub fn parse(self: *Self) ParserError!ParsedFile {
        const class_name_token: TokenId = self.next_token_id;
        _ = try self.eat_token(.identifier);
        _ = try self.eat_token_match_string(.binary_selector, "=");

        const maybe_super_class: ?TokenId = get_super_class: {
            const expected_str = "Expected a name of the super class or the class definition.";
            const token_id = self.next_token_id;
            const token: Token = self.peek_next_token() orelse {
                self.reporter.report_unexpected_eof(expected_str, .{});
                return ParserError.unexpected_eof;
            };
            switch (token.kind) {
                .identifier => {
                    _ = self.next_token();
                    break :get_super_class token_id;
                },
                .open_parenthesis => break :get_super_class null,
                else => {
                    self.reporter.report_error(
                        .{ .pos = token.pos },
                        "Unexpected token {t} '{s}'. " ++ expected_str,
                        .{ token.kind, self.text_at(token) },
                    );
                    return ParserError.unexpected_token;
                },
            }
        };

        _ = try self.eat_token(.open_parenthesis);

        const instance_portion = try self.parse_class_ast_portion(true);
        const class_portion = try self.parse_maybe_class_portion();

        const closing_parenthesis_token: TokenId = self.next_token_id;
        _ = try self.eat_token(.close_parenthesis);

        const class_ast = ClassAst{
            .class_name = class_name_token,
            .parent_class_name = maybe_super_class,
            .instance_portion = instance_portion,
            .class_portion = class_portion,
            .span = TokenSpan.create(class_name_token.idx, closing_parenthesis_token.idx),
        };

        self.ast.class_ast = class_ast;
        return self.ast;
    }

    fn parse_maybe_class_portion(self: *Self) ParserError!ClassAstPortion {
        const expected_str = "Expected either a separator `-----`, a method definition, or a closing parenthesis `)`";
        const maybe_separator = self.peek_next_token() orelse {
            self.reporter.report_unexpected_eof(expected_str, .{});
            return ParserError.unexpected_eof;
        };
        switch (maybe_separator.kind) {
            .separator => {
                _ = self.next_token();
                return try self.parse_class_ast_portion(false);
            },
            .close_parenthesis => return ClassAstPortion.empty(),
            else => |tag| {
                self.reporter.report_error(.{ .pos = maybe_separator.pos }, "Unexpected token: '{t}'. " ++ expected_str, .{tag});
                return ParserError.unexpected_token;
            },
        }
    }

    fn parse_class_ast_portion(self: *Self, comptime instance: bool) ParserError!ClassAstPortion {
        // Parse fields
        //
        // NOTE: We have to check if the current character is a symbol *and* if it is not a definition of a field.
        //       We can do that by checking if the token is or is not an equal sign.
        //       For more info, see "pipe_as_binary_message.som" in the snapshot tests.
        var fields: ?TokenSpan = null;
        if (self.peek_next_token()) |token_1| if (self.peek_token_at_offset(2)) |token_2| {
            const token_2_text = self.text_at(token_2);
            const is_token_2_equal_sign: bool = std.mem.eql(u8, "=", token_2_text);

            if (self.is_token_pipe(token_1) and !is_token_2_equal_sign) {
                const what_is_being_parsed = if (instance) "instance" else "class" ++ " fields";
                fields = try self.parse_locals(what_is_being_parsed);
            }
        };

        // Parse method definitions
        var method_definitions = std.ArrayList(MethodAst).empty;
        while (self.peek_next_token()) |method_header_token| {
            const method_header: MethodHeader = switch (method_header_token.kind) {
                .identifier => self.parse_unary_method_header(),
                .binary_selector => try self.parse_binary_method_header(),
                .keyword => try self.parse_keyword_method_header(),
                else => break,
            };
            _ = try self.eat_token_match_string(.binary_selector, "=");

            const body_start_token_id = self.next_token_id;
            const parenthesis_or_primitive_keyword = self.peek_next_token() orelse {
                self.reporter.report_unexpected_eof("Expected either '(' or 'primitive'.", .{});
                return ParserError.unexpected_eof;
            };
            const method_definition = sw: switch (parenthesis_or_primitive_keyword.kind) {
                .open_parenthesis => {
                    _ = self.next_token();
                    const method_body = try self.parse_function_body();
                    const end_token: TokenId = self.next_token_id;
                    _ = try self.eat_token(.close_parenthesis);
                    break :sw MethodAst{
                        .body = .{ .impl = method_body },
                        .header = method_header,
                        .span = TokenSpan.create(method_header.span().start_id.idx, end_token.idx),
                    };
                },
                else => |kind| {
                    const token_text: []const u8 = self.ast.text_at(parenthesis_or_primitive_keyword);
                    if (kind == .identifier and std.mem.eql(u8, token_text, "primitive")) {
                        _ = self.next_token();
                        break :sw MethodAst{
                            .body = .primitive,
                            .header = method_header,
                            .span = TokenSpan.create(method_header.span().start_id.idx, body_start_token_id.idx),
                        };
                    }
                    self.reporter.report_error(
                        .{ .pos = parenthesis_or_primitive_keyword.pos },
                        "Unexpected token {t} '{s}'. Expected token '(' or 'primitive'.",
                        .{ kind, token_text },
                    );
                    return ParserError.unexpected_token;
                },
            };

            try method_definitions.append(self.allocator, method_definition);
        }

        return .{
            .methods = try method_definitions.toOwnedSlice(self.allocator),
            .fields = fields,
        };
    }

    fn parse_unary_method_header(self: *Self) MethodHeader {
        const method_name_token: TokenId = self.next_token_id;
        _ = self.next_token().?;
        return MethodHeader{ .unary = .{ .selector = method_name_token } };
    }

    fn parse_binary_method_header(self: *Self) ParserError!MethodHeader {
        const method_name_token: TokenId = self.next_token_id;
        _ = self.next_token().?;

        const parameter_token: TokenId = self.next_token_id;
        _ = try self.eat_token(.identifier);

        return MethodHeader{ .binary = .{ .selector = method_name_token, .parameter = parameter_token } };
    }

    fn parse_keyword_method_header(self: *Self) ParserError!MethodHeader {
        const start_token_id: TokenId = self.next_token_id;
        // NOTE: we are not consuming the `.keyword_message` token here.
        // It will get consumed in the while loop below.

        const end_token_id: TokenId = while (true) {
            const maybe_keyword_token_id = self.next_token_id;
            const maybe_keyword_token = self.peek_next_token() orelse {
                self.reporter.report_unexpected_eof("Expected the rest of the keyword method definition.", .{});
                return ParserError.unexpected_eof;
            };

            // Parse the keyword
            const expected_keyword_str = "Unexpected token: '{t}'. Expected a keyword (an identifier with `:` at the end) or a method body `= ( \"some code\" )`.";
            switch (maybe_keyword_token.kind) {
                .keyword => _ = self.next_token(),
                .identifier => {
                    self.reporter.report_error(.{ .pos = maybe_keyword_token.pos }, expected_keyword_str, .{maybe_keyword_token.kind});
                    const hint_pos = CodePosition.at(maybe_keyword_token.pos.end_idx_inclusive() + 1);
                    self.reporter.add_note(.{ .pos = hint_pos }, "You probably wanted to put a `:` here.", .{});
                    return ParserError.unexpected_token;
                },
                .binary_selector => {
                    const token_text = self.text_at(maybe_keyword_token);
                    const is_equal_sign: bool = std.mem.eql(u8, token_text, "=");
                    if (is_equal_sign) break maybe_keyword_token_id.minus(1); // `maybe_keyword_token_id` is poiting at the equal sign and we want a token before that
                    self.reporter.report_error(.{ .pos = maybe_keyword_token.pos }, expected_keyword_str, .{maybe_keyword_token.kind});
                    return ParserError.unexpected_token;
                },
                else => {
                    self.reporter.report_error(.{ .pos = maybe_keyword_token.pos }, expected_keyword_str, .{maybe_keyword_token.kind});
                    return ParserError.unexpected_token;
                },
            }

            // Parse the identifier
            const maybe_param_token: Token = self.peek_next_token() orelse {
                self.reporter.report_unexpected_eof("Expected a parameter", .{});
                self.reporter.add_note(.{ .pos = maybe_keyword_token.pos }, "Parameter is expected because of this keyword here.", .{});
                return ParserError.unexpected_eof;
            };

            switch (maybe_param_token.kind) {
                .identifier => _ = self.next_token(),
                else => |tag| {
                    self.reporter.report_error(.{ .pos = maybe_param_token.pos }, "Unexpected token: '{t}'. Expected a parameter (which is an identifier).", .{tag});

                    const token_text = self.text_at(maybe_param_token);
                    if (tag == .keyword) {
                        const hint_pos = CodePosition.at(maybe_param_token.pos.end_idx_inclusive());
                        self.reporter.add_note(.{ .pos = hint_pos }, "Remove this `:` to make the `{s}` into a parameter.", .{token_text});
                    } else if (tag == .binary_selector and std.mem.eql(u8, token_text, "=")) {
                        self.reporter.add_note(.{ .pos = maybe_keyword_token.pos }, "You can provide a parameter after this keyword.", .{});
                    } else {
                        self.reporter.add_note(.{ .pos = maybe_keyword_token.pos }, "Parameter is expected because of this keyword here.", .{});
                    }
                    return ParserError.unexpected_token;
                },
            }
        } else unreachable; // All paths are either via `break` or `return` (this is maybe why Rust has a `loop` construct :D)

        const header_span = TokenSpan.create(start_token_id.idx, end_token_id.idx);
        const keyword_header = KeywordMethodHeader.create(header_span);
        return MethodHeader{ .keyword = keyword_header };
    }

    /// Parses:
    /// ```som
    ///     :param1 :param2 :param3 ... :paramN |
    ///        ^
    ///    expected `self.next_token_idx`
    /// ```
    /// and returns `TokenSpan` spanning tokens `:param1` to `:paramN`
    ///
    fn parse_block_parameters(self: *Self) ParserError!?TokenSpan {
        var result_span: TokenSpan = TokenSpan.at(self.next_token_id);
        _ = try self.eat_token(.block_param);

        while (true) {
            const token = self.peek_next_token() orelse {
                self.reporter.report_unexpected_eof("Expected more block parameters or a `|`.", .{});
                return ParserError.unexpected_eof;
            };
            switch (token.kind) {
                .block_param => result_span.end_id.idx += 1,
                else => |tag| {
                    if (self.is_token_pipe(token)) {
                        _ = self.next_token();
                        return result_span;
                    }
                    self.reporter.report_error(.{ .pos = token.pos }, "Unexpected token: '{t}'. Expected to see another block parameter or a `|`.", .{tag});
                    if (tag == .identifier) {
                        const hint_pos = CodePosition.at(token.pos.start_idx - 1);
                        self.reporter.add_note(.{ .pos = hint_pos }, "You might have forgotten a `:` here to make it a block parameter.", .{});
                    } else if (tag == .keyword) {
                        const parameter_text = self.text_at(token.pos.offset_start_by(1));
                        self.reporter.add_note(.{ .pos = token.pos }, "You probably might have wanted a block parameter, which would be '{s}:'", .{parameter_text});
                    }
                    return ParserError.unexpected_token;
                },
            }
            _ = self.next_token();
        }
    }

    fn parse_block_literal(self: *Self) ParserError!Spanned(BlockLiteral) {
        const open_bracket_token: TokenId = self.next_token_id;
        const open_bracket_pos = try self.eat_token(.open_bracket);

        const first_token = self.peek_next_token() orelse {
            self.reporter.report_unexpected_eof("Expected a block literal after a `[`", .{});
            return ParserError.unexpected_eof;
        };

        const parameters: ?TokenSpan = get_params: {
            if (first_token.kind == .block_param) {
                break :get_params try self.parse_block_parameters();
            }
            break :get_params null;
        };
        const first_parameter_token: ?TokenId = if (parameters) |p| p.start_id else null;

        const body = try self.parse_function_body();
        const body_id = try self.ast.extras.add_function_body(self.allocator, body);

        const close_bracket_token: TokenId = self.next_token_id;
        _ = self.eat_token(.close_bracket) catch |err| {
            self.reporter.add_note(.{ .pos = open_bracket_pos }, "The ']' is expected because of an opening `[` here.", .{});
            return err;
        };

        return Spanned(BlockLiteral){
            .inner = BlockLiteral.create(first_parameter_token, body_id),
            .span = TokenSpan.create(open_bracket_token.idx, close_bracket_token.idx),
        };
    }

    /// Parses:
    /// ```som
    ///     | var1 var2 var3  ...  varN |
    ///     ^
    ///  expected `self.next_token_idx`
    /// ```
    /// and returns `TokenSpan` spanning tokens `var1` to `varN`.
    ///
    /// Argument `structure_name` is for error reporting.
    /// Probably one of "instance fields", "class fields", "locals of a method", "locals of a block".
    ///
    fn parse_locals(self: *Self, comptime structure_name: []const u8) ParserError!?TokenSpan {
        // Consume the pipe token
        const start_pos = self.next_token().?.pos;
        const first_var_token_idx = self.next_token_id.idx;

        while (true) {
            const token = self.peek_next_token() orelse {
                self.reporter.report_unexpected_eof("Expected `|` to close the list of " ++ structure_name ++ ".", .{});
                self.reporter.add_note(.{ .pos = start_pos }, "The list of " ++ structure_name ++ " starts here.", .{});
                return ParserError.unmatched_pipe;
            };
            switch (token.kind) {
                .identifier => _ = self.next_token(),
                else => {
                    if (self.is_token_pipe(token)) {
                        _ = self.next_token();
                        break;
                    }
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

    fn parse_function_body(self: *Self) ParserError!FunctionBody {
        const start_token_id: TokenId = self.next_token_id;

        // Parse local variables
        const locals: ?TokenSpan = parse_locals: {
            const token = self.peek_next_token() orelse {
                self.reporter.report_unexpected_eof("Expected body of function or a closing parenthesis.", .{});
                return ParserError.unexpected_eof;
            };
            if (self.is_token_pipe(token)) {
                break :parse_locals try self.parse_locals("locals of a function body");
            } else {
                break :parse_locals null;
            }
        };

        // Later we create a `?TokenSpan` from `start_token_id` and `end_token_id`.
        // It is important to set `end_token_id` to a value that is *before* than the start.
        // The `end_token_id` gets updated in the while loop of parsing expressions,
        //   so if there is at least one expression, it will be set to that.
        var end_token_id = start_token_id.minus(1);

        // Parse list of expressions
        var expressions = std.ArrayList(ExprId).empty;
        var saw_dot = false;
        while (self.peek_next_token()) |token| : (end_token_id = self.next_token_id.minus(1)) {
            const expr_id: ExprId = get_expr: switch (token.kind) {
                .exit => {
                    const exit_token_id: TokenId = self.next_token_id;
                    _ = self.next_token(); // Consume the exit token
                    const return_value: ExprId = self.parse_expression() catch |err| {
                        self.reporter.add_note(.{ .pos = token.pos }, "An expression is expected because of an exit token here.", .{});
                        return err;
                    };
                    const last_return_value_token = self.span_of(return_value).end_id;
                    break :get_expr try self.add_expression(SpannedExpr{
                        .expr = Expression{ .exit_expression = .{ .return_value = return_value } },
                        .span = TokenSpan.create(exit_token_id.idx, last_return_value_token.idx),
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

            // Skip all dot tokens and set `saw_dot` to true if we see at least one dot.
            try expressions.append(self.allocator, expr_id);
            while (self.peek_next_token()) |maybe_dot| {
                if (maybe_dot.kind != .dot) break;
                saw_dot = true;
                _ = self.next_token();
            } else saw_dot = false;
        }

        const body = FunctionBody{
            .locals = locals,
            .expressions = try expressions.toOwnedSlice(self.allocator),
            .span = TokenSpan.create_or_null(start_token_id.idx, end_token_id.idx),
        };
        return body;
    }

    fn TODO(self: *Self, comptime fmt: []const u8) ParserError {
        self.reporter.report_error(.no_location, "TODO: " ++ fmt, .{});
        return ParserError.TODO;
    }

    fn parse_expression(self: *Self) ParserError!ExprId {
        const primary_expr_id: ExprId = try self.parse_primary();
        const token = self.peek_next_token() orelse return primary_expr_id;

        // Check whether this expression is an assignment or not
        if (token.kind == .assign) {
            const lhs_identifier: TokenId = switch (self.ast.get_expr(primary_expr_id)) {
                .variable => |identifier_token| identifier_token,
                else => |unexpected_expr_tag| {
                    self.reporter.report_error(
                        .{ .pos = self.pos_of(primary_expr_id) },
                        "Only a variable can be on the left hand side of an assignment.",
                        .{},
                    );
                    self.reporter.add_note(
                        .no_location,
                        "The expression recognised here is '{t}'.",
                        .{unexpected_expr_tag},
                    );
                    return ParserError.non_variable_used_as_lhs_of_expression;
                },
            };
            _ = self.next_token(); // Consume the assignment operator token
            const rhs_expression_id = try self.parse_expression();
            const rhs_last_token: TokenId = self.span_of(rhs_expression_id).end_id;

            return self.add_expression(.{
                .expr = Expression{ .assignment = .{
                    .variable = lhs_identifier,
                    .target_value = rhs_expression_id,
                } },
                .span = TokenSpan.create(lhs_identifier.idx, rhs_last_token.idx),
            });
        }

        return try self.parse_maybe_messages(primary_expr_id);
    }

    fn parse_maybe_messages(self: *Self, primary_expr_id: ExprId) ParserError!ExprId {
        const first_argument_id = try self.parse_maybe_binary_messages(primary_expr_id);
        var keyword_arguments = std.ArrayList(ExprId).empty;

        // Parse keyword message calls
        while (self.peek_next_token()) |token| {
            if (token.kind != .keyword) break;
            const keyword_token_id = self.next_token_id;
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

            // Append the keyword to the list of arguments
            //
            // NOTE: The AST stores the keyword arguments as a slice of `ExprId`s even
            // when every other is actually a `TokenId` pointing to a `.keyword` token.
            // This is because `Extras` is implemented to primarily store slices of `ExprId`.
            //
            // This means, that we have to cast the `keyword_token_id` into an `ExprId` in order to store it.
            try keyword_arguments.append(self.allocator, ExprId{ .idx = keyword_token_id.idx });

            // Append the argument for the keyword to the list of arguments
            try keyword_arguments.append(self.allocator, argument_id);
        }
        // We didn't parse any keyword pairs, so the resulting expression is not a keyword message call
        if (keyword_arguments.items.len == 0) return first_argument_id;

        const args_slice: []ExprId = try keyword_arguments.toOwnedSlice(self.allocator);
        const args_id: ExprSpanId = try self.ast.extras.add_variable_span(self.allocator, args_slice);

        const expression = Expression{ .keyword_message_send = .{
            .first_argument = first_argument_id,
            .args_id = args_id,
        } };
        const span = TokenSpan.create(
            self.span_of(first_argument_id).start_id.idx,
            self.span_of(args_slice[args_slice.len - 1]).end_id.idx,
        );
        return try self.add_expression(SpannedExpr{ .expr = expression, .span = span });
    }

    fn parse_maybe_binary_messages(self: *Self, lhs_expr_id: ExprId) ParserError!ExprId {
        var result_expr_id: ExprId = try self.parse_maybe_unary_messages(lhs_expr_id);

        while (self.peek_next_token()) |message_token| {
            if (message_token.kind != .binary_selector) break;
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

            const binary_call = BinaryMessageSend{
                .lhs = result_expr_id,
                .message = message_token_id,
                .rhs = rhs_expr_id,
            };
            const raw_binary_call: RawBinaryMessageSend = try binary_call.compress_allocating(self.allocator, &self.ast.extras);
            const expression = Expression{ .binary_message_send = raw_binary_call };
            const span = TokenSpan.create(
                self.span_of(binary_call.lhs).start_id.idx,
                self.span_of(binary_call.rhs).end_id.idx,
            );
            result_expr_id = try self.add_expression(SpannedExpr{ .expr = expression, .span = span });
        }
        return result_expr_id;
    }

    fn parse_maybe_unary_messages(self: *Self, primary_expr_id: ExprId) ParserError!ExprId {
        const start_token_id: TokenId = self.span_of(primary_expr_id).start_id;
        var result_expr_id = primary_expr_id;
        while (self.peek_next_token()) |unary_message_name| {
            if (unary_message_name.kind != .identifier) break;
            const unary_message_name_id = self.next_token_id;
            _ = self.next_token();

            // Append the message call
            const expression = Expression{ .unary_message_send = .{
                .argument = result_expr_id,
                .message = unary_message_name_id,
            } };
            result_expr_id = try self.add_expression(SpannedExpr{
                .expr = expression,
                .span = TokenSpan.create(start_token_id.idx, unary_message_name_id.idx),
            });
        }
        return result_expr_id;
    }

    inline fn pos_of(self: *Self, id: anytype) CodePosition {
        return self.pos_of_typed(@TypeOf(id), id);
    }

    inline fn pos_of_typed(self: *Self, comptime T: type, id: T) CodePosition {
        return switch (T) {
            ExprId => self.pos_of_typed(TokenSpan, self.span_of(id)),
            *const Token, *Token, Token => id.pos,
            TokenId => self.ast.tokens.items(.pos)[id.idx],
            TokenSpan => id.to_pos(self.ast.tokens),
            else => @compileError(
                "The method `pos_of` takes either `Token`, `*(const) Token`, `TokenId`, `TokenSpan` or `ExprId`. Got: `" ++ @typeName(T) ++ "`",
            ),
        };
    }

    fn parse_primary(self: *Self) ParserError!ExprId {
        // This function should be called only when we expect a primary
        const token_id = self.next_token_id;
        const token = self.next_token() orelse {
            self.reporter.report_unexpected_eof("Expected an expression.", .{});
            return ParserError.unexpected_eof;
        };
        const expression: SpannedExpr = get_expression: switch (token.kind) {
            .identifier => {
                break :get_expression SpannedExpr{
                    .expr = .{ .variable = token_id },
                    .span = TokenSpan.at(token_id),
                };
            },
            .integer => {
                break :get_expression SpannedExpr{
                    .expr = .{ .integer_literal = .{
                        .absolute_value_token = token_id,
                        .is_negative = false,
                    } },
                    .span = TokenSpan.at(token_id),
                };
            },
            .float => {
                break :get_expression SpannedExpr{
                    .expr = .{ .float_literal = .{
                        .absolute_value_token = token_id,
                        .is_negative = false,
                    } },
                    .span = TokenSpan.at(token_id),
                };
            },
            .string_literal => {
                break :get_expression SpannedExpr{
                    .expr = .{ .string_literal = token_id },
                    .span = TokenSpan.at(token_id),
                };
            },
            .array_literal_begin => {
                self.unget_token();
                const array_literal: Spanned(ArrayLiteral) = try self.parse_array_literal();
                const expr = SpannedExpr{ .expr = .{ .array_literal = array_literal.inner }, .span = array_literal.span };
                break :get_expression expr;
            },
            .open_parenthesis => {
                const inner_expression: ExprId = try self.parse_expression();
                _ = try self.eat_token(.close_parenthesis);

                // Adjust the span of the inner expression, since it is surrounded by parenthesis
                const original_span = self.span_of(inner_expression);
                const new_span = TokenSpan.create(original_span.start_id.idx - 1, original_span.end_id.idx + 1);
                self.ast.expressions.set_span_of(inner_expression, new_span);

                return inner_expression;
            },
            .open_bracket => {
                self.unget_token();
                const block_info = try self.parse_block_literal();
                const block_expr = SpannedExpr{
                    .expr = .{ .block_literal = block_info.inner },
                    .span = block_info.span,
                };
                break :get_expression block_expr;
            },
            .hashtag => {
                self.unget_token();
                const symbol_span: TokenSpan = try self.parse_som_symbol();
                const symbol_expr = SpannedExpr{ .expr = .{ .symbol = symbol_span }, .span = symbol_span };
                break :get_expression symbol_expr;
            },

            .close_parenthesis => {
                self.reporter.report_error(.{ .pos = token.pos }, "Unmatched parenthesis found. Expected an expression.", .{});
                return ParserError.unmatched_parenthesis;
            },
            .close_bracket => {
                self.reporter.report_error(.{ .pos = token.pos }, "Unmatched bracket found. Expected an expression.", .{});
                return ParserError.unmatched_bracket;
            },
            .binary_selector => {
                const binary_selector_text = self.text_at(token);
                const is_minus = std.mem.eql(u8, "-", self.ast.text_at(token));
                const number_token_id = self.next_token_id;
                const maybe_number_token = self.next_token();
                const is_next_token_number = if (maybe_number_token) |m| m.kind == .integer or m.kind == .float else false;
                const number_literal_span = TokenSpan.create(token_id.idx, token_id.idx + 1);

                if (!is_minus) {
                    const only_contains_plus_or_minus = for (binary_selector_text) |chr| {
                        if (chr != '-' and chr != '+') break false;
                    } else true;
                    if (only_contains_plus_or_minus and is_next_token_number) {
                        self.reporter.report_error(
                            .{ .pos = self.ast.pos_of(number_literal_span) },
                            "Number literals can only have a single minus '-' in front of them.",
                            .{},
                        );
                        return ParserError.unexpected_token;
                    }
                }

                if (!is_next_token_number or !is_minus) {
                    self.reporter.report_error(.{ .pos = token.pos }, "Unexpected 'binary selector' token. Expected an expression.", .{});
                    return ParserError.unexpected_token;
                }
                // SAFETY: `is_next_token_number` is true from the `if` above. Which implies that there was a token.
                const number_token = maybe_number_token.?;

                break :get_expression SpannedExpr{
                    .expr = switch (number_token.kind) {
                        .integer => .{ .integer_literal = .{
                            .absolute_value_token = number_token_id,
                            .is_negative = true,
                        } },
                        .float => .{ .float_literal = .{
                            .absolute_value_token = number_token_id,
                            .is_negative = true,
                        } },
                        // SAFETY: `is_next_token_number` is true, so only a float or an integer can be the kind of such token
                        else => unreachable,
                    },
                    .span = number_literal_span,
                };
            },
            // List all token kinds here so if there is a change to the list of token kinds, we catch it here and decide what to do.
            .exit, .separator, .dot, .assign, .keyword, .block_param => {
                self.reporter.report_error(.{ .pos = token.pos }, "Unexpected token: {t}. Expected an expression.", .{token.kind});
                return ParserError.unexpected_token;
            },
        };

        return self.add_expression(expression);
    }

    inline fn is_token_pipe(self: Self, token: Token) bool {
        return is_pipe(token, self.ast.source_code);
    }

    fn parse_som_symbol(self: *Self) ParserError!TokenSpan {
        const hashtag_token_id: TokenId = self.next_token_id;
        const hashtag_pos = try self.eat_token(.hashtag);

        const expected_str = "The character `#` is expected to have one of these after it: a string, an identifier, a binary message or a list of keywords (for example `#some:keywords:`).";
        const token_id = self.next_token_id;
        const token = self.next_token() orelse {
            self.reporter.report_unexpected_eof(expected_str, .{});
            return ParserError.alone_hashtag;
        };
        const token_is_right_after_hashtag: bool = (token.pos.start_idx == hashtag_pos.end_idx_inclusive() + 1);
        if (!token_is_right_after_hashtag) {
            const error_pos = CodePosition.at(hashtag_pos.end_idx_inclusive() + 1);
            self.reporter.report_error(.{ .pos = error_pos }, expected_str, .{});
            print_hint: {
                // Check if the user might wants to remove spaces before the next token
                const t = self.peek_next_token() orelse break :print_hint;
                switch (t.kind) {
                    .string_literal, .identifier, .binary_selector, .keyword => {},
                    else => break :print_hint,
                }
                const note_pos = CodePosition.from_start_and_end(token.pos.end_idx_inclusive() + 1, t.pos.start_idx - 1);
                self.reporter.add_note(
                    .{ .pos = note_pos },
                    "Since the next token after the hashtag is '{t}', consider removing this space between the tokens.",
                    .{t.kind},
                );
            }
            return ParserError.alone_hashtag;
        }

        const end_token_id: TokenId = blk: switch (token.kind) {
            .string_literal,
            .identifier,
            .binary_selector,
            => break :blk token_id,

            .keyword => {
                // Go through consecutive tokens that are keyword messages
                var previous_end_idx = token.pos.end_idx_inclusive();
                var end_token_idx = token_id.idx;

                while (self.peek_next_token()) |current_token| {
                    const current_start_idx = current_token.pos.start_idx;
                    const token_is_right_after_previous: bool = (current_start_idx == previous_end_idx + 1);
                    if (!token_is_right_after_previous or current_token.kind != .keyword) {
                        break :blk TokenId.create(end_token_idx);
                    }
                    _ = self.next_token();
                    previous_end_idx = current_token.pos.end_idx_inclusive();
                    end_token_idx += 1;
                }
                unreachable;
            },

            else => |tag| {
                self.reporter.report_error(.{ .pos = token.pos }, "Unexpected token '{t}'. " ++ expected_str, .{tag});
                return ParserError.unexpected_token;
            },
        };

        const span = TokenSpan.create(hashtag_token_id.idx, end_token_id.idx);
        return span;
    }

    fn parse_array_literal(self: *Self) ParserError!Spanned(ArrayLiteral) {
        const start_token = self.next_token_id;
        const start_pos = try self.eat_token(.array_literal_begin);

        var elements_list = std.ArrayList(ExprId).empty;
        var end_token = start_token;
        while (true) {
            end_token = self.next_token_id;
            const token = self.peek_next_token() orelse {
                self.reporter.report_unexpected_eof("Expected closing parenthesis for an array literal.", .{});
                self.reporter.add_note(.{ .pos = start_pos }, "Array literal starts here.", .{});
                return ParserError.unexpected_eof;
            };
            if (token.kind == .close_parenthesis) {
                _ = self.next_token();
                break;
            }

            // We want to parse primary here and not an entire expression, because of
            // cases such as `#(10 -20)` that should get parsed as `#((10) (-20))`, instead of `#((10 - 20))`.
            //
            // This does not limit having arbitrary expresssions in array literals,
            // we just have to wrap such expressions in parenthesis - like doing `#( (10-20) )`.
            const array_element: ExprId = self.parse_primary() catch |err| {
                if (err == error.OutOfMemory) return err;
                self.reporter.add_note(.{ .pos = start_pos }, "The error occured while trying to parse an element of an array literal that starts here.", .{});
                self.reporter.add_note(.no_location, "If you want to have an element that is a more complex expression (for example a 'binary message send'), wrap that element in parenthesis.", .{});
                return err;
            };
            try elements_list.append(self.allocator, array_element);
        }
        const elements: []ExprId = try elements_list.toOwnedSlice(self.allocator);
        const elements_id: ExprSpanId = try self.ast.extras.add_variable_span(self.allocator, elements);

        const spanned_literal = Spanned(ArrayLiteral){
            .inner = ArrayLiteral{ .elements = elements_id },
            .span = TokenSpan.create(start_token.idx, end_token.idx),
        };
        return spanned_literal;
    }

    fn add_expression(self: *Self, new_expression: SpannedExpr) ParserError!ExprId {
        const new_expr_id: ExprId = try self.ast.expressions.add(self.allocator, new_expression);
        return new_expr_id;
    }

    fn span_of(self: Self, id: ExprId) TokenSpan {
        return self.ast.expressions.span_of(id);
    }

    inline fn text_at(self: Self, id: anytype) []const u8 {
        return self.ast.text_at(id);
    }

    fn eat_token_match_string(self: *Self, comptime expected_kind: TokenKind, comptime expected_text: []const u8) ParserError!CodePosition {
        const actual_token = self.next_token() orelse {
            self.reporter.report_unexpected_eof("Expected token '{s}'.", .{expected_text});
            return ParserError.unexpected_eof;
        };

        const kind_matches = actual_token.kind == expected_kind;
        const actual_text = self.text_at(actual_token);
        const text_matches = std.mem.eql(u8, actual_text, expected_text);
        //
        if (text_matches) {
            assert(kind_matches);
            return actual_token.pos;
        }

        self.reporter.report_error(
            .{ .pos = actual_token.pos },
            "Unexpected token '{s}'. Expected token '{s}'.",
            .{ actual_text, expected_text },
        );
        return ParserError.unexpected_token;
    }

    fn eat_token(self: *Self, comptime expected_kind: TokenKind) ParserError!CodePosition {
        const actual_token = self.next_token() orelse {
            self.reporter.report_unexpected_eof("Expected token of kind '{t}'.", .{expected_kind});
            return ParserError.unexpected_eof;
        };
        if (actual_token.kind != expected_kind) {
            return self.report_unexpected_token(actual_token, expected_kind);
        }
        return actual_token.pos;
    }

    fn report_unexpected_token(self: *Self, actual_token: Token, expected_kind: TokenKind) ParserError {
        self.reporter.report_error(
            .{ .pos = actual_token.pos },
            "Unexpected token {t} '{s}'. Expected token '{t}'.",
            .{ actual_token.kind, self.text_at(actual_token), expected_kind },
        );
        return ParserError.unexpected_token;
    }

    fn peek_next_token(self: Self) ?Token {
        if (@as(usize, self.next_token_id.idx) >= self.ast.tokens.len) {
            return null;
        }
        return self.ast.get_token(self.next_token_id);
    }

    fn unget_token(self: *Self) void {
        assert(self.next_token_id.idx > 0);
        self.next_token_id.idx -= 1;
    }

    fn next_token(self: *Self) ?Token {
        const token = self.peek_next_token();
        self.next_token_id.idx += 1;
        return token;
    }

    fn peek_token_at_offset(self: *Self, offset: i32) ?Token {
        if (self.next_token_id.idx < offset) return null;
        const idx = self.next_token_id.idx + @abs(std.math.sign(offset) * offset);
        if (idx >= self.ast.tokens.len) return null;
        return self.ast.tokens.get(idx);
    }
};

const SpanFormatter = struct {
    tokens: std.MultiArrayList(Token).Slice,
    const Fmt = struct {
        tokens: std.MultiArrayList(Token).Slice,
        span: ?TokenSpan,

        pub fn format(self: *const @This(), w: *std.io.Writer) std.io.Writer.Error!void {
            if (self.span) |span| {
                const pos = span.to_pos(self.tokens);
                try w.print("[{d:3}..{d:3}]", .{ pos.start_idx, pos.end_idx_inclusive() });
            } else {
                try w.print("[empty   ]", .{});
            }
        }
    };

    pub fn fmt(self: *const @This(), span: ?TokenSpan) Fmt {
        return .{ .span = span, .tokens = self.tokens };
    }

    pub fn fmt_token(self: *const @This(), token: TokenId) Fmt {
        return .{ .span = TokenSpan.at(token), .tokens = self.tokens };
    }
};

const Indent = struct {
    const Self = @This();
    tab_count: i32,

    pub fn create(tab_count: i32) Self {
        assert(tab_count >= 0);
        return Indent{ .tab_count = tab_count };
    }

    pub fn plus(self: *const Self, offset: i32) Self {
        return Indent.create(self.tab_count + offset);
    }

    pub fn format(self: *const Self, writer: *std.io.Writer) std.io.Writer.Error!void {
        for (0..@intCast(self.tab_count)) |_| {
            try writer.print("\t", .{});
        }
    }
};

const PrintFunctionBodyError = ParserError || std.io.Writer.Error;
fn print_function_body(
    writer: *std.io.Writer,
    function_body: FunctionBody,
    formatter: SpanFormatter,
    ast: ParsedFile,
    indent: Indent,
) PrintFunctionBodyError!void {
    try writer.print("{f}\t{f}Body:\n", .{ indent, formatter.fmt(function_body.span) });
    if (function_body.locals) |span_locals| {
        try writer.print("{f}\t\tLocals:\n", .{indent});
        var iter = span_locals.iter();
        var idx: usize = 1;
        while (iter.next()) |token_id| : (idx += 1) {
            assert(ast.kind_of(token_id) == .identifier);
            const local = ast.text_at(token_id);
            try writer.print("{f}\t\t\t#{d}: '{s}'\n", .{ indent, idx, local });
        }
    } else {
        try writer.print("{f}\t\t(no locals)\n", .{indent});
    }
    const expressions = function_body.expressions;
    if (expressions.len != 0) {
        try writer.print("{f}\t\tExpressions:\n", .{indent});
    } else {
        try writer.print("{f}\t\t(no expressions)\n", .{indent});
    }
    for (expressions, 1..) |expr, idx| {
        try writer.print("{f}\t\t\tExpression #{d}:\n", .{ indent, idx });

        const new_indent = indent.plus(4); // because we want at least 4 tabulators before each expression
        try print_expression_recursive(writer, formatter, expr, ast, new_indent);
    }
}

fn print_expression_recursive(
    writer: *std.io.Writer,
    formatter: SpanFormatter,
    expr_id: ExprId,
    ast: ParsedFile,
    indent: Indent,
) !void {
    const expression = ast.expressions.get(expr_id);

    try writer.print("{f}- {f}(id={d}) ", .{
        indent,
        formatter.fmt(ast.span_of(expr_id)),
        expr_id.idx,
    });
    switch (expression) {
        .variable => |identifier_token| try writer.print("Variable({s})\n", .{ast.text_at(identifier_token)}),
        .integer_literal => |literal_info| {
            const value_str = ast.text_at(literal_info.absolute_value_token);
            const sign_str = if (literal_info.is_negative) "-" else "";
            try writer.print("Integer literal({s}{s})\n", .{ sign_str, value_str });
        },
        .float_literal => |literal_info| {
            const value_str = ast.text_at(literal_info.absolute_value_token);
            const sign_str = if (literal_info.is_negative) "-" else "";
            try writer.print("Float literal({s}{s})\n", .{ sign_str, value_str });
        },
        .string_literal => |token_id| {
            const value = ast.text_at(token_id);
            // Strip the leading and trailing `'`
            assert(value.len >= 2); // It should be, since the shortest string literal is `''` (two `'` characters)
            const stripped = value[1 .. value.len - 1];
            try writer.print("String literal({s})\n", .{stripped});
        },
        .array_literal => |array_literal| {
            const elements: []const ExprId = ast.extras.variable_span_of(array_literal.elements);

            switch (elements.len) {
                0 => try writer.print("Array literal (empty)\n", .{}),
                1 => {
                    try writer.print("Array literal (with 1 element):\n", .{});
                    const element = elements[0];
                    try print_expression_recursive(writer, formatter, element, ast, indent.plus(1));
                },
                else => {
                    try writer.print("Array literal (with {d} elements):\n", .{elements.len});
                    for (elements) |element| {
                        try print_expression_recursive(writer, formatter, element, ast, indent.plus(1));
                    }
                },
            }
        },
        .symbol => {
            const text: []const u8 = ast.text_at(expr_id);
            try writer.print("Symbol '{s}'\n", .{text});
        },

        .exit_expression => |exit| {
            try writer.print("Exit expression with return value:\n", .{});
            try print_expression_recursive(writer, formatter, exit.return_value, ast, indent.plus(1));
        },
        .assignment => |assignment| {
            try writer.print("Assignment of '{s}' to:\n", .{ast.text_at(assignment.variable)});
            try print_expression_recursive(writer, formatter, assignment.target_value, ast, indent.plus(1));
        },

        .block_literal => |info| {
            try writer.print("{f} Block literal", .{formatter.fmt(ast.span_of(expr_id))});
            const parameters = info.get_parameters(ast.tokens);
            if (parameters) |span_parameters| {
                try writer.print(" with {d} parameters:\n", .{span_parameters.number_of_tokens()});
                var iter = span_parameters.iter();
                while (iter.next()) |parameter_token| {
                    const parameter_text = ast.text_at(parameter_token);
                    try writer.print("{f}- '{s}'\n", .{ indent.plus(1), parameter_text });
                }
            } else {
                try writer.print(" with no parameters\n", .{});
            }

            const body = ast.extras.function_body_of(info.body_id);
            try print_function_body(writer, body, formatter, ast, indent);
        },

        .unary_message_send => |unary_call| {
            try writer.print("Unary message '{s}' to the object:\n", .{ast.text_at(unary_call.message)});
            try print_expression_recursive(writer, formatter, unary_call.argument, ast, indent.plus(1));
        },
        .binary_message_send => |raw_binary_call| {
            const binary_call = raw_binary_call.decompress(ast.extras);

            try writer.print("Binary message call '{s}', with lhs:\n", .{ast.text_at(binary_call.message)});
            try print_expression_recursive(writer, formatter, binary_call.lhs, ast, indent.plus(1));

            try writer.print("{f}  and rhs:\n", .{indent});
            try print_expression_recursive(writer, formatter, binary_call.rhs, ast, indent.plus(1));
        },
        .keyword_message_send => |keyword_call| {
            try writer.print("Keyword message call on object:\n", .{});
            try print_expression_recursive(writer, formatter, keyword_call.first_argument, ast, indent.plus(1));

            try writer.print("{f}  and argument pairs:\n", .{indent});

            const args = keyword_call.get_args(ast.extras);
            for (0..args.number_of_args()) |idx_usize| {
                const idx: u32 = @truncate(idx_usize);
                try writer.print("{f}- Keyword '{s}' and arg:\n", .{ indent.plus(1), ast.text_at(args.nth_keyword(idx)) });
                try print_expression_recursive(writer, formatter, args.nth_argument(idx), ast, indent.plus(2));
            }
        },
    }
}

fn print_portion(
    ast: ParsedFile,
    portion: *const ClassAstPortion,
    span_formatter: SpanFormatter,
    writer: *std.io.Writer,
) !void {
    if (portion.fields) |span_fields| {
        try writer.print("\tFields:\n", .{});
        var iter = span_fields.iter();
        while (iter.next()) |token_id| {
            assert(ast.kind_of(token_id) == .identifier);
            const text = ast.text_at(token_id);
            try writer.print("\t\t- '{s}'\n", .{text});
        }
    } else {
        try writer.print("\t(no fields)\n", .{});
    }

    if (portion.methods.len == 0) {
        try writer.print("\t(no methods)\n", .{});
    }

    for (portion.methods, 1..) |method, method_idx| {
        try writer.print("{f}Method #{d}:\n", .{ span_formatter.fmt(method.span), method_idx });

        const header = method.header;
        try writer.print("\t{f}Header: ", .{span_formatter.fmt(header.span())});
        switch (header) {
            .unary => |info| {
                try writer.print("(unary-method) '{s}'\n", .{ast.text_at(info.selector)});
            },
            .binary => |info| {
                try writer.print("(binary-method) '{s}' with parameter '{s}'\n", .{
                    ast.text_at(info.selector), ast.text_at(info.parameter),
                });
            },
            .keyword => |info| {
                try writer.print("(keyword-method) ", .{});
                for (0..info.number_of_args_excluding_self()) |idx| {
                    const keyword = ast.text_at(info.nth_keyword(@truncate(idx)));
                    const parameter = ast.text_at(info.nth_parameter(@truncate(idx)));
                    if (idx != 0) try writer.print(" | ", .{});
                    try writer.print("'{s}' '{s}'", .{ keyword, parameter });
                }
                try writer.print("\n", .{});
            },
        }
        switch (method.body) {
            .impl => |function_body| try print_function_body(writer, function_body, span_formatter, ast, Indent.create(0)),
            .primitive => try writer.print("\t\t- (primitive)\n", .{}),
        }
    }
}

pub fn print_class_ast(
    input: []const u8,
    gpa: std.mem.Allocator,
    writer: *std.io.Writer,
    err_writer: *std.io.Writer,
) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    var reporter = ErrorReporter{
        .writer = err_writer,
        .use_color = false,
        .source = input,
        .source_path = null,
    };
    const tokenized_file: TokenizedFile = lexer_module.tokenize(.{
        .allocator = allocator,
        .reporter = &reporter,
        .source_code = input,
        .source_code_filepath = null,
    }) catch |init_error| {
        try err_writer.print("Failed with parser init error (probably lexing error): '{t}'\n", .{init_error});
        return;
    };
    const parsed_file: ParsedFile = blk: {
        var parser = Parser.create(tokenized_file, &reporter, allocator);
        break :blk parser.parse() catch |parse_error| {
            try err_writer.print("Failed with parse error: '{t}'\n", .{parse_error});
            return;
        };
    };
    const class_ast: ClassAst = parsed_file.class_ast;

    const span_formatter = SpanFormatter{ .tokens = parsed_file.tokens };

    try writer.print("AST of the class {f}'{s}'", .{
        span_formatter.fmt(class_ast.span), parsed_file.text_at(class_ast.class_name),
    });
    if (class_ast.parent_class_name) |super_name| {
        try writer.print(" (super = '{s}')\n", .{parsed_file.text_at(super_name)});
    } else {
        try writer.print("\n", .{});
    }

    try writer.print("==== Instance specific part ====\n", .{});
    try print_portion(parsed_file, &class_ast.instance_portion, span_formatter, writer);

    try writer.print("==== Class specific part ====\n", .{});
    try print_portion(parsed_file, &class_ast.class_portion, span_formatter, writer);
}

test "snapshot test on example files" {
    const snapshot_testing = @import("../snapshot_testing.zig");
    const opts = snapshot_testing.opts;
    if (opts.test_parser_files_path.len == 0) return;
    try snapshot_testing.do_snapshot_tests(.{
        .snapshots_directory = opts.snapshots_path ++ "/parser",
        .tested_files_directory = opts.test_parser_files_path,
        .output_producer = print_class_ast,
    }, "Parsing");
}
