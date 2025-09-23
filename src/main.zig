const std = @import("std");
const dbg = std.debug.print;

const int = i64;
const uint = u64;

const Token = struct {
    const Self = @This();

    kind: TokenKind,
    position: CodePosition,

    pub fn len(self: *const Self) int {
        return switch (self.kind) {
            .Number => |number_token_info| number_token_info.source_code_length,
            // single character tokens
            else => 1,
        };
    }

    pub fn location(self: *const Self) CodeLocation {
        return self.position.to_location(self.len());
    }
};

const NumberToken = struct {
    value: uint,
    source_code_length: int,
};

const TokenKind = union(enum) {
    Plus,
    Minus,
    Asterisk,
    Slash,
    Hat,
    OpenParenthesis,
    CloseParenthesis,
    Number: NumberToken,
};

const Precedence = int;
const MIN_PRECEDENCE: Precedence = 0;
const Associativity = enum { Left, Right };

const BinOpInfo = struct {
    precedence: Precedence,
    associativity: Associativity = .Left,
    kind: BinOpKind,
};

fn get_binop_info(token: TokenKind) ?BinOpInfo {
    return switch (token) {
        .Plus => BinOpInfo{ .precedence = MIN_PRECEDENCE + 1, .kind = .Addition },
        .Minus => BinOpInfo{ .precedence = MIN_PRECEDENCE + 1, .kind = .Subtraction },
        .Asterisk => BinOpInfo{ .precedence = MIN_PRECEDENCE + 2, .kind = .Multiplication },
        .Slash => BinOpInfo{ .precedence = MIN_PRECEDENCE + 2, .kind = .Division },
        .Hat => BinOpInfo{ .precedence = MIN_PRECEDENCE + 3, .associativity = .Right, .kind = .Exponentiation },
        else => null,
    };
}

const LexerError = error{
    UnknownChar,
    NumberIsTooBigToParse,
};

/// Unicode character
const Char = u21;

fn is_whitespace(c: Char) bool {
    return switch (c) {
        ' ', '\t'...'\r' => true,
        else => false,
    };
}

fn add_digit(old_value: uint, digit: u21) !uint {
    var new_value = old_value;
    new_value = try std.math.mul(uint, new_value, 10);
    new_value = try std.math.add(uint, new_value, digit - '0');
    return new_value;
}

const Lexer = struct {
    const Self = @This();

    /// Position which will be read next
    position: CodePosition = CodePosition{ .line = 1, .column = 1, .char_idx = 0 },

    char_iterator: std.unicode.Utf8Iterator,
    buffer_for_peeked_token: ?Token = null,
    buffer_for_peeked_char: ?Char = null,

    pub fn peek_token(self: *Self) LexerError!?Token {
        if (self.buffer_for_peeked_token) |t| return t;

        self.buffer_for_peeked_token = try self.next_token();
        return self.buffer_for_peeked_token;
    }

    pub fn next_token(self: *Self) LexerError!?Token {
        if (self.buffer_for_peeked_token) |buffered_token| {
            self.buffer_for_peeked_token = null;
            return buffered_token;
        }

        self.skip_whitespace();

        const start_token_position = self.position;

        const current_char = self.peek_char() orelse return null;
        const token_kind = blk: switch (current_char) {
            '*' => {
                self.next_char();
                break :blk TokenKind.Asterisk;
            },
            '+' => {
                self.next_char();
                break :blk TokenKind.Plus;
            },
            '-' => {
                self.next_char();
                break :blk TokenKind.Minus;
            },
            '/' => {
                self.next_char();
                break :blk TokenKind.Slash;
            },
            '^' => {
                self.next_char();
                break :blk TokenKind.Hat;
            },
            else => |c| {
                if (c <= std.math.maxInt(u8) and std.ascii.isDigit(@intCast(c))) {
                    const number = try self.parse_number();
                    break :blk TokenKind{ .Number = number };
                }

                var buf: [4]u8 = undefined;
                if (std.unicode.utf8Encode(c, &buf) catch null) |len| {
                    self.report_error("Invalid character: '{s}'", .{buf[0..len]});
                } else {
                    self.report_error("Invalid character which is an invalid unicode character with value 0x{x}", .{c});
                }

                return LexerError.UnknownChar;
            },
        };
        self.buffer_for_peeked_token = null;

        const token = Token{
            .kind = token_kind,
            .position = start_token_position,
        };
        return token;
    }

    fn peek_char(self: *Self) ?Char {
        if (self.buffer_for_peeked_char) |chr| return chr;
        self.buffer_for_peeked_char = self.char_iterator.nextCodepoint();
        return self.buffer_for_peeked_char;
    }

    fn next_char(self: *Self) void {
        self.buffer_for_peeked_char = null;
        self.position.char_idx += 1;
        self.position.column += 1;
    }

    fn skip_whitespace(self: *Self) void {
        while (true) {
            const chr = self.peek_char() orelse break;
            if (!is_whitespace((chr))) break;
            self.next_char();

            if (chr == '\n') {
                self.position.column = 1;
                self.position.line += 1;
            }
        }
    }

    fn parse_number(self: *Self) LexerError!NumberToken {
        var parsed_value: uint = 0;
        var source_code_length: int = 0;

        while (true) {
            const chr = self.peek_char() orelse break;
            if (!is_digit(chr)) break;

            parsed_value = add_digit(parsed_value, chr) catch {
                self.report_error("Could not parse a number, because it was too big", .{});
                return LexerError.NumberIsTooBigToParse;
            };
            source_code_length += 1;

            self.next_char();
        }

        return NumberToken{ .value = parsed_value, .source_code_length = source_code_length };
    }

    fn is_digit(chr: Char) bool {
        if (chr > std.math.maxInt(u8)) return false;
        return std.ascii.isDigit(@intCast(chr));
    }

    pub fn report_error(self: *Self, comptime fmt: []const u8, args: anytype) void {
        // TODO: proper logging later :D
        std.debug.print("[LEXING-ERROR at {any}] " ++ fmt ++ "\n", .{self.position} ++ args);
    }
};

pub fn todo() noreturn {
    @panic("There is a TODO in the code :)\n");
}

const ParserError = LexerError || error{ UnexpectedEof, UnexpectedToken } || std.mem.Allocator.Error;

const Ast = struct {
    const Self = @This();

    nodes: std.ArrayList(AstNode),
    allocator: std.mem.Allocator,

    pub fn new_with_allocator(allocator: std.mem.Allocator) Self {
        return Self{ .allocator = allocator, .nodes = .{} };
    }

    pub fn add_node(self: *Self, node: AstNode) std.mem.Allocator.Error!AstNodeIndex {
        const new_node_idx: AstNodeIndex = @intCast(self.nodes.items.len);
        try self.nodes.append(self.allocator, node);
        return new_node_idx;
    }
};

const Parser = struct {
    const Self = @This();
    lexer: Lexer,
    ast: Ast,

    fn report_error_at(self: *Self, location: CodeLocation, comptime fmt: []const u8, args: anytype) void {
        _ = self;
        // TODO: proper logging later :D
        const pos = location.position;
        std.debug.print("[PARSE-ERROR at col {d} line {d}] " ++ fmt ++ "\n", .{ pos.column, pos.line } ++ args);
    }

    fn report_error_at_end(self: *Self, comptime fmt: []const u8, args: anytype) void {
        _ = self;
        // TODO: proper logging later :D
        std.debug.print("[PARSE-ERROR at end of input] " ++ fmt ++ "\n", args);
    }

    fn report_error(self: *Self, comptime fmt: []const u8, args: anytype) void {
        _ = self;
        // TODO: proper logging later :D
        std.debug.print("[PARSE-ERROR] " ++ fmt ++ "\n", args);
    }

    fn error_with_unexpected_eof(
        self: *Self,
        comptime expected_fmt: []const u8,
        expected_args: anytype,
    ) ParserError {
        self.report_error_at_end(
            "Unexpected end of input, expected: " ++ expected_fmt,
            expected_args,
        );
        return ParserError.UnexpectedEof;
    }

    fn error_with_unexpected_token(
        self: *Self,
        actual_token: Token,
        comptime expected_fmt: []const u8,
        expected: anytype,
    ) ParserError {
        self.report_error_at(
            actual_token.location(),
            "Unexpected token '{s}', expected: " ++ expected_fmt,
            .{@tagName(actual_token.kind)} ++ expected,
        );
        return ParserError.UnexpectedToken;
    }

    pub fn parse_expression(self: *Self) ParserError!AstNodeIndex {
        return self.parse_expression_inner(0);
    }

    fn parse_atom(self: *Self) ParserError!AstNodeIndex {
        const token = try self.lexer.peek_token() orelse {
            return self.error_with_unexpected_eof("{s}", .{"an expression (specifically an atom)"});
        };

        switch (token.kind) {
            .OpenParenthesis => {
                const sub_expression = try self.parse_expression();
                _ = try self.eat_and_assert_token(TokenKind.CloseParenthesis);
                return sub_expression;
            },
            .Number => |number_token| {
                _ = try self.lexer.next_token();
                return self.ast.add_node(AstNode{
                    .location = token.location(),
                    .kind = AstNodeKind{ .Number = number_token.value },
                });
            },
            //Token.Identifier => { TODO :) }
            else => {
                return self.error_with_unexpected_token(token, "{s}", .{"an expression (specifically an atom)"});
            },
        }
    }

    fn eat_and_assert_token(
        self: *Self,
        expected_token: TokenKind,
    ) ParserError!CodeLocation {
        const actual_token = try self.lexer.next_token() orelse {
            // @would-be-nice: Get the actual string for the expected token, not just print 'any'
            return self.error_with_unexpected_eof("token '{any}'", .{expected_token});
        };

        if (@intFromEnum(actual_token.kind) != @intFromEnum(expected_token)) {
            // @would-be-nice: Get the actual string for the expected token, not just print 'any'
            return self.error_with_unexpected_token(actual_token, "{any}", .{expected_token});
        }

        return actual_token.location();
    }

    fn parse_expression_inner(self: *Self, min_precedence: Precedence) ParserError!AstNodeIndex {
        var lhs = try self.parse_atom();

        while (true) {
            const token = try self.lexer.peek_token() orelse break;
            const binary_op = get_binop_info(token.kind) orelse break;
            if (binary_op.precedence < min_precedence) break;
            _ = try self.lexer.next_token();

            const next_expression_min_precedence = switch (binary_op.associativity) {
                .Left => binary_op.precedence + 1,
                .Right => binary_op.precedence,
            };

            const rhs = try self.parse_expression_inner(next_expression_min_precedence);

            lhs = try self.ast.add_node(AstNode{
                .kind = AstNodeKind{ .BinOp = .{
                    .kind = binary_op.kind,
                    .lhs = lhs,
                    .rhs = rhs,
                } },
                .location = token.location(),
            });
        }

        return lhs;
    }
};

const CodePosition = struct {
    const Self = @This();

    line: int,
    column: int,
    char_idx: int,

    pub fn to_location(self: *const Self, len: int) CodeLocation {
        return CodeLocation{
            .position = self.*,
            .len = len,
        };
    }
};

const CodeLocation = struct {
    position: CodePosition,
    len: int,
};

const AstNodeIndex = int;

const AstNode = struct {
    location: CodeLocation,
    kind: AstNodeKind,
};

const BinOpKind = enum {
    Addition,
    Subtraction,
    Multiplication,
    Division,
    Exponentiation,
};

const BinOp = struct {
    kind: BinOpKind,
    lhs: AstNodeIndex,
    rhs: AstNodeIndex,
};

const AstNodeKind = union(enum) {
    Number: uint,
    BinOp: BinOp,
};

pub fn main() !void {
    std.debug.print("This will be an amazing {s} project.\n\n", .{"SOMig"});

    const input = "10 + 20 / 30";

    {
        const iterator = (try std.unicode.Utf8View.init(input)).iterator();
        var lexer = Lexer{ .char_iterator = iterator };
        std.debug.print("Tokens from:\n   >{s}<\nGot parsed into:\n", .{input});
        while (try lexer.next_token()) |token| {
            std.debug.print(" - {any}\n", .{token});
        }
    }

    {
        var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
        const general_allocator = gpa.allocator();
        const iterator = (try std.unicode.Utf8View.init(input)).iterator();
        const lexer = Lexer{ .char_iterator = iterator };
        var parser = Parser{ .lexer = lexer, .ast = Ast.new_with_allocator(general_allocator) };
        const root_expr = try parser.parse_expression();
        dbg("Parsed this ast:\n", .{});
        try print_ast(parser.ast, root_expr);
    }
}

fn print_ast(ast: Ast, root: AstNodeIndex) !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    try print_ast_inner(ast, root, stdout, 0);
    try stdout.flush();
    errdefer _ = stdout.flush() catch {};
}

fn print_ast_inner(ast: Ast, root_idx: AstNodeIndex, stdout: *std.io.Writer, depth: uint) !void {
    const root = ast.nodes.items[@intCast(root_idx)];

    for (0..depth) |_| {
        try stdout.print(" ", .{});
    }

    switch (root.kind) {
        .Number => |number_value| {
            try stdout.print("Number({d})\n", .{number_value});
        },
        .BinOp => |binop| {
            try stdout.print("{s}:\n", .{@tagName(binop.kind)});
            try print_ast_inner(ast, binop.lhs, stdout, depth + 1);
            try print_ast_inner(ast, binop.rhs, stdout, depth + 1);
        },
    }
}

// test "simple test" {
//     const gpa = std.testing.allocator;
//     var list: std.ArrayList(i32) = .empty;
//     defer list.deinit(gpa); // Try commenting this out and see if zig detects the memory leak!
//     try list.append(gpa, 42);
//     try std.testing.expectEqual(@as(i32, 42), list.pop());
// }

const expect_equal = std.testing.expectEqual;
const expect = std.testing.expect;
test "lexer peek test" {
    //             0123456789
    const input = "10 + 200 / 3";

    const expected_tokens = [_]Token{
        .{
            .position = .{ .char_idx = 0, .column = 1, .line = 1 },
            .kind = .{ .Number = .{ .source_code_length = 2, .value = 10 } },
        },
        .{
            .position = .{ .char_idx = 3, .column = 4, .line = 1 },
            .kind = .Plus,
        },
        .{
            .position = .{ .char_idx = 5, .column = 6, .line = 1 },
            .kind = .{ .Number = .{ .source_code_length = 3, .value = 200 } },
        },
        .{
            .position = .{ .char_idx = 9, .column = 10, .line = 1 },
            .kind = .Slash,
        },
        .{
            .position = .{ .char_idx = 11, .column = 12, .line = 1 },
            .kind = .{ .Number = .{ .source_code_length = 1, .value = 3 } },
        },
    };

    const iterator = (try std.unicode.Utf8View.init(input)).iterator();
    var lexer = Lexer{ .char_iterator = iterator };

    try expect_equal(lexer.buffer_for_peeked_token, null);

    for (expected_tokens) |expected_token| {
        for (0..5) |_| { // Try multiple times to peek the token multiple times
            try expect_equal(try lexer.peek_token(), expected_token);
            try expect(lexer.buffer_for_peeked_token != null);
        }
        try expect_equal(try lexer.next_token(), expected_token);
        try expect_equal(lexer.buffer_for_peeked_token, null);
    }

    try expect_equal(lexer.next_token(), null);
    try expect_equal(lexer.peek_token(), null);
}
