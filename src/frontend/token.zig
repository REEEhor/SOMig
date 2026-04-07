// Grammar src
// https://github.com/SOM-st/SOM/blob/a721b4ff6ecb1ade54e0afe0bd15a8e80e41af17/specification/SOM.g4

const std = @import("std");
const Allocator = std.mem.Allocator;

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
    start_idx: u32,
    length: u32,

    /// Creates a position in code of a single character.
    pub fn at(start_index: u32) CodePosition {
        return CodePosition{
            .start_idx = start_index,
            .length = 1,
        };
    }

    pub fn from_start_and_end(start_index: u32, end_index_inclusive: u32) CodePosition {
        std.debug.assert(start_index <= end_index_inclusive);
        return CodePosition{
            .start_idx = start_index,
            .length = end_index_inclusive - start_index + 1,
        };
    }

    pub fn offset_start_by(self: Self, offset: u32) CodePosition {
        return CodePosition.from_start_and_end(
            self.start_idx + offset,
            self.end_idx_inclusive(),
        );
    }

    pub fn end_idx_inclusive(self: Self) u32 {
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

/// TODO: Rename to `Tag`
pub const TokenKind = enum(u8) {
    const Self = @This();

    /// The `^` character
    exit,

    /// An identifier consiting only from `-` with length at least 4. For example: `-----`.
    separator,

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
    binary_selector,

    /// String in the form of `someIdentifier:`
    keyword,

    /// Identifiers in SOM consist of 'a'...'z', 'A'...'Z', '0'...'9' (<- not at the start), '_'
    identifier,

    /// String in the form of `:someIdentifier`
    block_param,
};

/// TODO: Rename `kind` to `tag`
pub const Token = struct {
    const Self = @This();
    kind: TokenKind,
    pos: CodePosition,
};

pub const minimal_separator_length = 4;

pub inline fn is_pipe(token: Token, source_code: []const u8) bool {
    return source_code[token.pos.start_idx] == '|';
}

/// Index into the list of all tokens in `Tokenized`
pub const TokenId = struct {
    idx: u32,

    pub fn create(idx: u32) TokenId {
        return TokenId{ .idx = idx };
    }

    pub fn minus(self: @This(), offset: u32) TokenId {
        return TokenId{ .idx = self.idx - offset };
    }

    pub fn plus(self: @This(), offset: u32) TokenId {
        return TokenId{ .idx = self.idx + offset };
    }
};

/// Span of tokens which represent different pieces of the AST
pub const TokenSpan = struct {
    /// Index into the token array where the first token is.
    start_id: TokenId,
    /// Index into the token array where the last (including) token is.
    end_id: TokenId,

    const Self = @This();

    /// Factory method
    pub fn create(start_idx: u32, end_idx: u32) Self {
        return Self.create_or_null(start_idx, end_idx).?;
    }

    /// Factory method
    pub fn at(token_id: TokenId) Self {
        return TokenSpan{ .start_id = token_id, .end_id = token_id };
    }

    /// Factory method
    pub fn create_or_null(start_idx: u32, end_idx: u32) ?Self {
        if (end_idx < start_idx) return null;
        return TokenSpan{
            .start_id = TokenId.create(start_idx),
            .end_id = TokenId.create(end_idx),
        };
    }

    pub fn to_pos(self: Self, tokens: std.MultiArrayList(Token).Slice) CodePosition {
        const start_pos: CodePosition = tokens.items(.pos)[self.start_id.idx];
        const end_pos: CodePosition = tokens.items(.pos)[self.end_id.idx];
        return CodePosition.from_start_and_end(
            start_pos.start_idx,
            end_pos.end_idx_inclusive(),
        );
    }

    pub fn number_of_tokens(self: Self) u32 {
        return self.end_id.idx - self.start_id.idx + 1;
    }

    pub fn iter(self: Self) TokenSpanIterator {
        return TokenSpanIterator{
            .current = self.start_id,
            .last = self.end_id,
        };
    }

    pub fn iterator(span: ?TokenSpan) TokenSpanIterator {
        if (span) |s| return s.iter();
        return TokenSpanIterator.empty;
    }
};

pub const TokenSpanIterator = struct {
    current: TokenId,
    last: TokenId,

    const Self = @This();
    pub fn next(self: *Self) ?TokenId {
        if (self.current.idx > self.last.idx) return null;
        const result = self.current;
        self.current.idx += 1;
        return result;
    }

    pub const empty = TokenSpanIterator{ .current = TokenId.create(1), .last = TokenId.create(0) };
};

// TODO: think about also storing the filepath to this file
pub const TokenizedFile = struct {
    tokens: std.MultiArrayList(Token).Slice,
    source_code: []const u8,
    /// This field is `null` in case the source was not from a file.
    source_code_filepath: ?[]const u8,

    const Self = @This();

    pub fn deinit(self: *Self, allocator: Allocator) void {
        self.tokens.deinit(allocator);
    }

    pub fn pos_of(self: Self, id: anytype) CodePosition {
        return switch (@TypeOf(id)) {
            *Token, Token => id.pos,
            TokenId => self.tokens.items(.pos)[id.idx],
            TokenSpan => id.to_pos(self.ast.tokens),
            else => |T| @compileError(
                "The method `pos_of` takes either `Token`, `*Token`, `TokenId` or `TokenSpan`. Got: `" ++ @typeName(T) ++ "`",
            ),
        };
    }

    pub fn text_at(self: Self, id: anytype) []const u8 {
        const position = self.pos_of(id);
        return position.slice_from(self.source_code);
    }

    pub fn kind_of(self: Self, id: TokenId) TokenKind {
        return self.tokens.items(.kind)[id.idx];
    }

    pub fn get_token(self: Self, id: TokenId) Token {
        return self.tokens.get(id.idx);
    }

    pub fn total_token_span(self: Self) ?TokenSpan {
        if (self.tokens.len == 0) {
            return null;
        }
        return TokenSpan.create(0, @intCast(self.tokens.len - 1));
    }
};
test "slice_from" {
    const text = "0123456789";
    var buffer: [20]u8 = undefined;

    for (0..text.len) |idx| {
        const expected = try std.fmt.bufPrint(&buffer, "{c}", .{text[idx]});
        try std.testing.expectEqualStrings(expected, CodePosition.at(@intCast(idx)).slice_from(text));
    }

    for (0..text.len - 4) |idx| {
        const expected = try std.fmt.bufPrint(&buffer, "{c}{c}{c}{c}", .{
            text[idx],
            text[idx + 1],
            text[idx + 2],
            text[idx + 3],
        });
        const pos = CodePosition{ .start_idx = @intCast(idx), .length = 4 };
        try std.testing.expectEqualStrings(expected, pos.slice_from(text));
    }
}
