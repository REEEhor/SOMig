const std = @import("std");

const int = i64;
const uint = u64;

const Token = union(enum) {
    Plus,
    Minus,
    Asterisk,
    Slash,
    Hat,
    Number: uint,
};

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

    char_iterator: std.unicode.Utf8Iterator,
    buffer_for_peeked_token: ?Token = null,
    buffer_for_peeked_char: ?Char = null,

    pub fn peek_token(self: *Self) ?Token {
        if (self.buffer_for_peeked_token) |t| return t;

        self.buffer_for_peeked_token = self.next_token();
        return self.buffer_for_peeked_token;
    }

    pub fn next_token(self: *Self) LexerError!?Token {
        self.skip_whitespace();
        const current_char = self.peek_char() orelse return null;
        const token = blk: switch (current_char) {
            '*' => {
                self.next_char();
                break :blk Token.Asterisk;
            },
            '+' => {
                self.next_char();
                break :blk Token.Plus;
            },
            '-' => {
                self.next_char();
                break :blk Token.Minus;
            },
            '/' => {
                self.next_char();
                break :blk Token.Slash;
            },
            '^' => {
                self.next_char();
                break :blk Token.Hat;
            },
            else => |c| {
                if (c < std.math.maxInt(u8) and std.ascii.isDigit(@intCast(c))) {
                    const number = try self.parse_number();
                    break :blk Token{ .Number = number };
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
        return token;
    }

    fn peek_char(self: *Self) ?Char {
        if (self.buffer_for_peeked_char) |chr| return chr;
        self.buffer_for_peeked_char = self.char_iterator.nextCodepoint();
        return self.buffer_for_peeked_char;
    }

    fn next_char(self: *Self) void {
        self.buffer_for_peeked_char = null;
    }

    fn skip_whitespace(self: *Self) void {
        while (true) {
            const chr = self.peek_char() orelse break;
            if (!is_whitespace((chr))) break;
            self.next_char();
        }
    }

    fn parse_number(self: *Self) LexerError!uint {
        var result: uint = 0;

        while (true) {
            const chr = self.peek_char() orelse break;
            if (!is_digit(chr)) break;

            result = add_digit(result, chr) catch {
                self.report_error("Could not parse a number, because it was too big", .{});
                return LexerError.NumberIsTooBigToParse;
            };

            self.next_char();
        }

        return result;
    }

    fn is_digit(chr: Char) bool {
        if (chr > std.math.maxInt(u8)) return false;
        return std.ascii.isDigit(@intCast(chr));
    }

    pub fn report_error(self: *Self, comptime fmt: []const u8, args: anytype) void {
        _ = self;
        // TODO: proper logging later :D
        std.debug.print("[PARSE-ERROR] " ++ fmt ++ "\n", args);
    }
};

pub fn todo() noreturn {
    @compileError("There is a TODO in the code :)\n");
}

// const Ast = struct {};
// pub fn parse_expression(lexer: Lexer) !Ast {
//     lexer.peek();
//     return undefined;
// }

pub fn main() !void {
    std.debug.print("This will be an amazing {s} project.\n\n", .{"SOMig"});

    const input = "10 + 20 / 30";

    const iterator = (try std.unicode.Utf8View.init(input)).iterator();
    var lexer = Lexer{ .char_iterator = iterator };
    std.debug.print("Tokens from:\n   >{s}<\nGot parsed into:\n", .{input});
    while (try lexer.next_token()) |token| {
        std.debug.print(" - {any}\n", .{token});
    }
}

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa); // Try commenting this out and see if zig detects the memory leak!
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

test "fuzz example" {
    const Context = struct {
        fn testOne(context: @This(), input: []const u8) anyerror!void {
            _ = context;
            // Try passing `--fuzz` to `zig build test` and see if it manages to fail this test case!
            try std.testing.expect(!std.mem.eql(u8, "canyoufindme", input));
        }
    };
    try std.testing.fuzz(Context{}, Context.testOne, .{});
}
