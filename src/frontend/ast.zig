const std = @import("std");
const token_module = @import("token.zig");
const FloatRepresentation = token_module.FloatRepresentation;
const IntegerRepresentation = token_module.IntegerRepresentation;

/// Span of tokens which represent different pieces of the AST
const TokenSpan = struct {
    /// Index into the token array where the first token is.
    start_idx: usize,
    /// Index into the token array where the last (including) token is.
    end_idx: usize,
};

pub const ClassDefinition = struct {
    pos: TokenSpan,
    class_name: Identifier,
    methods: []MethodDefinition,

    // TODO:
    //  - Separate this into class and instance parts
    //  - Add instance+class fields
    //  - Add superclass
};

/// Method definition
pub const MethodDefinition = struct {
    pos: TokenSpan,
    header: MethodHeader,
    body: MethodBody,
};

pub const Identifier = []const u8;

pub const MethodHeader = struct {
    pos: TokenSpan,
    kind: MethodHeaderKind,
};

pub const MethodHeaderKind = union(enum) {
    unary: struct { method_name: Identifier },
    binary: struct { method_name: []const u8, parameter: Identifier },

    /// Keywords are parsed together with `:` at the end
    keyword: struct { keywords: []const []const u8, parameters: []Identifier },
};

pub const MethodBody = struct {
    pos: TokenSpan,
    locals: []Identifier,
    expressions: []ExprId,
};

/// Index into an array of expressions
pub const ExprId = u32;

pub const Expression = struct {
    pos: TokenSpan,
    kind: ExpressionKind,
};

// TODO:
//  - Add doc comments for each field (WITH SYNTAX EXAMPLE)
pub const ExpressionKind = union(enum) {
    assignment: struct { variables: []Identifier, target_value: ExprId },
    variable: struct { identifier: Identifier },
    integer_literal: IntegerRepresentation,
    float_literal: FloatRepresentation,
    string_literal: []const u8, // @cleanup: Maybe replace with index into an array of strings?

    unary_message_call: struct { argument: ExprId, message: Identifier },
    binary_message_call: struct { lhs: ExprId, rhs: ExprId, message: []const u8 },
    keyword_message_call: struct { keywords: []const []const u8, arguments: []Identifier },

    // TODO:
    //  - Add:
    //      - block (lambda in SOM)
    //      - integer literals
    //      - array literals
    //      - symbols (maybe)
    //      - that's it?
    //
    //  - Consider:
    //      Cases like `assignment` and `keyword_message_call` requires a lot of information.
    //      Maybe their contents could be stored somewhere else (like a big array).
    //      Actually, it might not matter, the expressions might get stored inside a `MultiArrayList`
    //      (and if they got stored inside normal `ArrayList`, it would have been still fine *except* for the padding)
    //
};
