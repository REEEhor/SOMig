// Grammar src
// https://github.com/SOM-st/SOM/blob/a721b4ff6ecb1ade54e0afe0bd15a8e80e41af17/specification/SOM.g4

const std = @import("std");
const int = i64;
const uint = u64;

// And              &
// At               @
// Comma            ,
// Div              /
// Equal            =
// Less             <
// Minus            -
// Mod              \\
// More             >
// Not              ~
// Or               |
// Per              %
// Plus             +
// Star             *

// &@,/=<-\>~|%+*

pub const CodePosition = struct {
    const Self = @This();
    start_idx: uint,
    length: uint,

    /// Creates a position in code of a single character.
    pub fn at(start_index: usize) CodePosition {
        return CodePosition{
            .start_idx = start_index,
            .length = 1,
        };
    }

    pub fn from_start_and_end(start_index: usize, end_index_inclusive: usize) CodePosition {
        std.debug.assert(start_index <= end_index_inclusive);
        return CodePosition{
            .start_idx = start_index,
            .length = end_index_inclusive - start_index + 1,
        };
    }

    pub fn offset_start_by(self: Self, offset: usize) CodePosition {
        return CodePosition.from_start_and_end(
            self.start_idx + offset,
            self.end_idx_inclusive(),
        );
    }

    pub fn end_idx_inclusive(self: Self) uint {
        return self.start_idx + self.length - 1;
    }

    pub fn slice_from(self: Self, text: []const u8) []const u8 {
        return text[self.start_idx .. self.end_idx_inclusive() + 1];
    }

    pub fn contains_byte_at(self: Self, byte_idx: usize) bool {
        return self.start_idx <= byte_idx and byte_idx <= self.end_idx_inclusive();
    }
};

pub const IntegerRepresentation = i64;
pub const FloatRepresentation = f64;

pub const TokenKind = enum(u8) {
    const Self = @This();

    /// The `^` character
    exit,

    /// The symbol `.`.
    /// Used for separating statements or expressions.
    dot,

    /// The symbol `:=`
    assign,

    /// The symbol `(`
    open_parenthesis,
    /// The symbol `)`
    close_parenthesis,

    /// The symbol `[`
    open_bracket,
    /// The symbol `]`
    close_bracket,

    /// Integer literal
    integer,

    /// Float literal
    float,

    /// The symbol `#(`
    array_literal_begin,

    /// The symbol `#`
    hashtag,

    /// String literal is enclosed in 'single quotes'.
    string_literal,

    /// Identifier which consists of: &@,/=<-\>~|%+*
    binary_message,

    /// String in the form of `someIdentifier:`
    keyword_message,

    /// Identifiers in SOM consist of 'a'...'z', 'A'...'Z', '0'...'9' (<- not at the start), '_'
    identifier,

    /// String in the form of `:someIdentifier`
    block_param,
};

pub const Token = struct {
    const Self = @This();
    kind: TokenKind,
    pos: CodePosition,
};

test "slice_from" {
    const text = "0123456789";
    var buffer: [20]u8 = undefined;

    for (0..text.len) |idx| {
        const expected = try std.fmt.bufPrint(&buffer, "{c}", .{text[idx]});
        try std.testing.expectEqualStrings(expected, CodePosition.at(idx).slice_from(text));
    }

    for (0..text.len - 4) |idx| {
        const expected = try std.fmt.bufPrint(&buffer, "{c}{c}{c}{c}", .{
            text[idx],
            text[idx + 1],
            text[idx + 2],
            text[idx + 3],
        });
        const pos = CodePosition{ .start_idx = idx, .length = 4 };
        try std.testing.expectEqualStrings(expected, pos.slice_from(text));
    }
}
