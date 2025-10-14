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

    pub fn end_idx_inclusive(self: *Self) uint {
        return self.start_idx + self.length - 1;
    }
};

pub const IntegerRepresentation = i64;
pub const FloatRepresentation = f64;

pub const TokenKind = union(enum) {
    /// The `^` character
    exit,

    /// Line `------`
    separator,

    pipe,
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

    integer: IntegerRepresentation,
    float: FloatRepresentation,

    /// The symbol `#(`
    array_literal_begin,

    /// The symbol `#`
    hashtag,

    /// The keyword `primitive`
    kw_primitive,

    /// String literal is enclosed in 'single quotes'.
    /// It is actually important to store also the contents of the string
    /// because of escape sequences like `\n` which are translated into
    /// corresponding ASCII values in the string.
    ///
    /// TODO: Consider allocating all string into an array so the token has to store only an index into that array.
    ///
    string_literal: []u8,

    /// Identifier consisting of: `&@,/=<-\>~|%+*`
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
