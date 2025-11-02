const std = @import("std");
const assert = std.debug.assert;
const token_module = @import("token.zig");
const FloatRepresentation = token_module.FloatRepresentation;
const IntegerRepresentation = token_module.IntegerRepresentation;
const Token = token_module.Token;
const CodePosition = token_module.CodePosition;

const TokenIdRepresentation = u32;

/// Index into the list of all tokens.
pub const TokenId = struct {
    idx: TokenIdRepresentation,
    pub fn create(idx: TokenIdRepresentation) TokenId {
        return TokenId{ .idx = idx };
    }
};

/// Span of tokens which represent different pieces of the AST
pub const TokenSpan = struct {
    const Self = @This();

    pub fn create(start_idx: TokenIdRepresentation, end_idx: TokenIdRepresentation) Self {
        return Self.create_or_null(start_idx, end_idx).?;
    }

    pub fn at(token_id: TokenId) Self {
        return TokenSpan{ .start_id = token_id, .end_id = token_id };
    }

    pub fn create_or_null(start_idx: TokenIdRepresentation, end_idx: TokenIdRepresentation) ?Self {
        if (end_idx < start_idx) return null;
        return TokenSpan{
            .start_id = TokenId.create(start_idx),
            .end_id = TokenId.create(end_idx),
        };
    }

    /// Index into the token array where the first token is.
    start_id: TokenId,
    /// Index into the token array where the last (including) token is.
    end_id: TokenId,

    pub fn number_of_tokens(self: *const Self) u32 {
        return self.end_id.idx - self.start_id.idx + 1;
    }

    pub fn to_pos(self: *const Self, tokens: []Token) CodePosition {
        const start_token = tokens[self.start_id.idx];
        const end_token = tokens[self.end_id.idx];
        return CodePosition.from_start_and_end(
            start_token.pos.start_idx,
            end_token.pos.end_idx_inclusive(),
        );
    }

    pub fn iter(self: *const Self) TokenSpanIterator {
        return TokenSpanIterator{
            .current = self.start_id,
            .last = self.end_id,
        };
    }
};

pub const TokenSpanIterator = struct {
    const Self = @This();
    current: TokenId,
    last: TokenId,
    pub fn next(self: *Self) ?TokenId {
        if (self.current.idx > self.last.idx) return null;
        const result = self.current;
        self.current.idx += 1;
        return result;
    }
};

pub const ClassDefinition = struct {
    span: TokenSpan,
    class_name: TokenId,
    instance_methods: []MethodDefinition,
    instance_fields: ?TokenSpan,

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

pub const MethodHeader = union(enum) {
    unary: struct { method_name: TokenId },
    binary: struct { method_name: TokenId, parameter: TokenId },
    keyword: KeywordMethodHeader,

    const Self = @This();
    pub fn span(self: *const Self) TokenSpan {
        return switch (self.*) {
            .unary => |info| TokenSpan.at(info.method_name),
            .binary => |info| TokenSpan.create(info.method_name.idx, info.parameter.idx),
            .keyword => |info| info.argument_pairs,
        };
    }
};

pub const KeywordMethodHeader = struct {
    const Self = @This();
    argument_pairs: TokenSpan,

    /// Keywords are parsed together with `:` at the end
    pub fn nth_keyword(self: *const Self, n: u32) TokenId {
        assert(n < self.number_of_args());
        return self.argument_pairs.start_id.idx + n * 2;
    }

    pub fn nth_parameter(self: *const Self, n: u32) TokenId {
        assert(n < self.number_of_args());
        return self.argument_pairs.start_id.idx + (n * 2) + 1;
    }

    pub fn number_of_args(self: *const Self) u32 {
        return self.argument_pairs.number_of_tokens() / 2;
    }
};

// TODO: reuse this also for the body of a block
pub const MethodBody = struct {
    span: TokenSpan,
    locals: ?TokenSpan,
    expressions: []ExprId,
};

/// Index into an array of expressions
pub const ExprId = struct { idx: u32 };

pub const ExpressionList = struct {
    const Self = @This();
    expressions: std.ArrayList(Expression),

    pub fn len(self: *const Self) usize {
        return self.expressions.items.len;
    }
    pub fn at(self: *const Self, id: ExprId) *Expression {
        return &self.expressions.items[id.idx];
    }
};

// TODO:
//  - Add doc comments for each field (WITH SYNTAX EXAMPLE)
pub const Expression = union(enum) {
    const Self = @This();

    variable: TokenId,

    integer_literal: TokenId,
    float_literal: TokenId,
    string_literal: TokenId,
    array_literal: ArrayLiteral,

    symbol: SomSymbol,

    exit_expression: struct { return_value: ExprId },
    assignment: struct { variable: TokenId, target_value: ExprId },

    unary_message_call: struct { argument: ExprId, message: TokenId },
    binary_message_call: struct { lhs: ExprId, rhs: ExprId, message: TokenId },
    keyword_message_call: struct { first_argument: ExprId, args: []KeywordArgumentPair },

    pub fn span(self: *const Self, expressions: ExpressionList) TokenSpan {
        return switch (self.*) {
            .variable => |token_id| TokenSpan.at(token_id),
            .integer_literal => |token_id| TokenSpan.at(token_id),
            .float_literal => |token_id| TokenSpan.at(token_id),
            .string_literal => |token_id| TokenSpan.at(token_id),
            .array_literal => |info| info.span,

            .symbol => |info| info.span,

            .assignment => |info| blk: {
                const start_id: TokenId = info.variable;
                const end_id: TokenId = expressions.at(info.target_value).span(expressions).end_id;
                break :blk TokenSpan.create(start_id.idx, end_id.idx);
            },
            .exit_expression => |info| blk: {
                const span_of_return_value: TokenSpan = expressions.at(info.return_value).span(expressions);
                break :blk TokenSpan.create(
                    span_of_return_value.start_id.idx - 1, // We have to account for the `^` token
                    span_of_return_value.end_id.idx,
                );
            },
            .unary_message_call => |info| blk: {
                const start_id: TokenId = expressions.at(info.argument).span(expressions).start_id;
                const end_id: TokenId = info.message;
                break :blk TokenSpan.create(start_id.idx, end_id.idx);
            },
            .binary_message_call => |info| blk: {
                const start_id: TokenId = expressions.at(info.lhs).span(expressions).start_id;
                const end_id: TokenId = expressions.at(info.rhs).span(expressions).end_id;
                break :blk TokenSpan.create(start_id.idx, end_id.idx);
            },
            .keyword_message_call => |info| blk: {
                const start_id: TokenId = expressions.at(info.first_argument).span(expressions).start_id;
                //
                const last_argument: ExprId = info.args[info.args.len - 1].argument;
                const end_id: TokenId = expressions.at(last_argument).span(expressions).end_id;
                //
                break :blk TokenSpan.create(start_id.idx, end_id.idx);
            },
        };
    }

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

pub const ArrayLiteral = struct {
    // We have to store the `span` separatelly in case it would be an empty array
    // In other cases, we could extract the `span` from `elements`.
    // So this type `ArrayLiteral` could also be an union, but that would be too un-ergonomic.
    // Also, it seems like we would not make the union `Expression` smaller.
    span: TokenSpan,
    elements: []ExprId,
};

pub const SomSymbol = struct {
    span: TokenSpan,
};

pub const KeywordArgumentPair = struct {
    /// Keyword contains even the parsed `:` at the end
    keyword: TokenId,
    argument: ExprId,
};
