const std = @import("std");
const token_module = @import("token.zig");
const FloatRepresentation = token_module.FloatRepresentation;
const IntegerRepresentation = token_module.IntegerRepresentation;
const Token = token_module.Token;
const CodePosition = token_module.CodePosition;

/// Span of tokens which represent different pieces of the AST
pub const TokenSpan = struct {
    /// Index into the token array where the first token is.
    start_idx: u32,
    /// Index into the token array where the last (including) token is.
    end_idx: u32,

    pub fn to_pos(self: *@This(), tokens: []Token) CodePosition {
        const start_token = tokens[self.start_idx];
        const end_token = tokens[self.end_idx];
        return CodePosition.from_start_and_end(
            start_token.pos.start_idx,
            end_token.pos.end_idx_inclusive(),
        );
    }
};

pub const ClassDefinition = struct {
    span: TokenSpan,
    class_name: Identifier,
    methods: []MethodDefinition,

    // TODO:
    //  - Separate this into class and instance parts
    //  - Add instance+class fields
    //  - Add superclass
};

/// Method definition
pub const MethodDefinition = struct {
    span: TokenSpan,
    header: MethodHeader,
    body: MethodBody,
};

pub const Identifier = []const u8;

pub const MethodHeader = struct {
    span: TokenSpan,
    kind: MethodHeaderKind,
};

pub const MethodHeaderKind = union(enum) {
    unary: struct { method_name: Identifier },
    binary: struct { method_name: []const u8, parameter: Identifier },

    /// Keywords are parsed together with `:` at the end
    keyword: struct { keywords: []const []const u8, parameters: []Identifier },
};

// TODO: reuse this also for the body of a block
pub const MethodBody = struct {
    span: TokenSpan,
    locals: []Identifier,
    expressions: []ExprId,
};

/// Index into an array of expressions
pub const ExprId = u32;

pub const Expression = struct {
    span: TokenSpan,
    kind: ExpressionKind,
};

pub const KeywordArgumentPair = struct {
    /// Keyword contains even the parsed `:` at the end
    keyword: []const u8,
    argument: ExprId,
};

// TODO:
//  - Add doc comments for each field (WITH SYNTAX EXAMPLE)
pub const ExpressionKind = union(enum) {
    assignment: struct { variable: Identifier, target_value: ExprId },
    variable: Identifier,
    integer_literal: IntegerRepresentation,
    float_literal: FloatRepresentation,
    string_literal: []const u8, // @cleanup: Maybe replace with index into an array of strings?

    exit_expression: struct { return_value: ExprId },

    unary_message_call: struct { argument: ExprId, message: Identifier },
    binary_message_call: struct { lhs: ExprId, rhs: ExprId, message: []const u8 },
    keyword_message_call: struct { first_argument: ExprId, args: []const KeywordArgumentPair },

    // TODO:
    //  - Add:
    //      - block (lambda in SOM)
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
