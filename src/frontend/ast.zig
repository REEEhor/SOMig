const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const token_module = @import("token.zig");
const FloatRepresentation = token_module.FloatRepresentation;
const IntegerRepresentation = token_module.IntegerRepresentation;
const Token = token_module.Token;
const CodePosition = token_module.CodePosition;

/// Index into the list of all tokens.
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
    const Self = @This();

    pub fn create(start_idx: u32, end_idx: u32) Self {
        return Self.create_or_null(start_idx, end_idx).?;
    }

    pub fn at(token_id: TokenId) Self {
        return TokenSpan{ .start_id = token_id, .end_id = token_id };
    }

    pub fn create_or_null(start_idx: u32, end_idx: u32) ?Self {
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

    pub fn number_of_tokens(self: Self) u32 {
        return self.end_id.idx - self.start_id.idx + 1;
    }

    pub fn to_pos(self: Self, tokens: []Token) CodePosition {
        const start_token = tokens[self.start_id.idx];
        const end_token = tokens[self.end_id.idx];
        return CodePosition.from_start_and_end(
            start_token.pos.start_idx,
            end_token.pos.end_idx_inclusive(),
        );
    }

    pub fn iter(self: Self) TokenSpanIterator {
        return TokenSpanIterator{
            .current = self.start_id,
            .last = self.end_id,
        };
    }
};

pub fn Spanned(comptime Inner: type) type {
    return struct {
        inner: Inner,
        span: TokenSpan,
    };
}

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

    instance_portion: ClassDefinitionPortion,
    class_portion: ClassDefinitionPortion,

    // TODO:
    //  - Add superclass
};

pub const ClassDefinitionPortion = struct {
    const Self = @This();
    methods: []MethodDefinition,
    fields: ?TokenSpan,
    pub fn empty() Self {
        return .{ .methods = &[0]MethodDefinition{}, .fields = null };
    }
};

/// Method definition
pub const MethodDefinition = struct {
    span: TokenSpan,
    header: MethodHeader,
    body: union(enum) { impl: FunctionBody, primitive },
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

    /// Creates a new instance of `KeywordMethodHeader`.
    /// Asserts, that the number of tokens in `argument_pairs` is non-zero and even.
    pub fn create(argument_pairs: TokenSpan) Self {
        assert(argument_pairs.number_of_tokens() > 0);
        assert(argument_pairs.number_of_tokens() % 2 == 0);
        return KeywordMethodHeader{ .argument_pairs = argument_pairs };
    }

    /// Keywords are parsed together with `:` at the end
    pub fn nth_keyword(self: *const Self, n: u32) TokenId {
        assert(n < self.number_of_args());
        return self.argument_pairs.start_id.plus(n * 2);
    }

    pub fn nth_parameter(self: *const Self, n: u32) TokenId {
        assert(n < self.number_of_args());
        return self.argument_pairs.start_id.plus(n * 2 + 1);
    }

    pub fn number_of_args(self: *const Self) u32 {
        return self.argument_pairs.number_of_tokens() / 2;
    }
};

pub const FunctionBody = struct {
    span: ?TokenSpan,
    locals: ?TokenSpan,
    expressions: []const ExprId,
};

pub const FunctionBodyId = struct { idx: u32 };

/// Index into an array of expressions
pub const ExprId = struct { idx: u32 };

pub const ExpressionList = struct {
    const Self = @This();
    expr_list: std.MultiArrayList(Expression),
    span_list: std.ArrayList(TokenSpan),

    pub const empty = ExpressionList{
        .expr_list = std.MultiArrayList(Expression).empty,
        .span_list = std.ArrayList(TokenSpan).empty,
    };

    pub fn add(self: *Self, allocator: Allocator, expr: SpannedExpr) Allocator.Error!ExprId {
        const new_expr_id = ExprId{ .idx = self.len() };
        try self.expr_list.append(allocator, expr.expr);
        try self.span_list.append(allocator, expr.span);
        return new_expr_id;
    }

    pub fn len(self: Self) u32 {
        return @truncate(self.span_list.items.len);
    }

    pub fn set_span_of(self: *Self, id: ExprId, new_span: TokenSpan) void {
        self.span_list.items[id.idx] = new_span;
    }

    pub fn span_of(self: Self, id: ExprId) TokenSpan {
        return self.span_list.items[id.idx];
    }

    pub fn get(self: Self, id: ExprId) Expression {
        return self.expr_list.get(id.idx);
    }

    pub fn get_with_span(self: Self, id: ExprId) SpannedExpr {
        return SpannedExpr{
            .span = self.span_of(id),
            .expr = self.get(id),
        };
    }

    pub fn tag_of(self: Self, id: ExprId) std.meta.Tag(Expression) {
        return self.expr_list.items(.tags)[id.idx];
    }
};

pub const Extras = struct {
    const Self = @This();
    extras: std.ArrayList(u32),

    pub const empty = Extras{ .extras = std.ArrayList(u32).empty };

    fn bytes_to_expr_ids(bytes: []const u32) []const ExprId {
        return std.mem.bytesAsSlice(ExprId, std.mem.sliceAsBytes(bytes));
    }

    fn expr_ids_to_bytes(ids: []const ExprId) []const u32 {
        return std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(ids));
    }

    pub fn add_variable_span(self: *Self, allocator: Allocator, span: []const ExprId) Allocator.Error!ExprSpanId {
        const result_span_id = ExprSpanId{ .idx = @truncate(self.extras.items.len) };
        const casted_span: []const u32 = expr_ids_to_bytes(span);

        // Append an `ExprId` which will be interpreted as the length of the span
        try self.extras.append(allocator, @truncate(span.len));
        try self.extras.appendSlice(allocator, casted_span);

        return result_span_id;
    }

    pub fn variable_span_of(self: Self, id: ExprSpanId) []const ExprId {
        // Interpret the first expression id as the length of the span
        const span_len: u32 = self.extras.items[id.idx];

        const start_idx: u32 = id.idx + 1;
        const end_idx_exclusive: u32 = start_idx + span_len;

        const slice: []u32 = self.extras.items[start_idx..end_idx_exclusive];
        const slice_expr: []ExprId = std.mem.bytesAsSlice(ExprId, std.mem.sliceAsBytes(slice));
        return slice_expr;
    }

    pub fn add_fixed_span(
        self: *Self,
        allocator: Allocator,
        comptime len: comptime_int,
        span: [len]ExprId,
    ) Allocator.Error!FixedExprSpanId(len) {
        const result_span_id = FixedExprSpanId(len){ .idx = @truncate(self.extras.items.len) };
        const slice: []const u32 = std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(span[0..]));
        try self.extras.appendSlice(allocator, slice);
        return result_span_id;
    }

    /// `id` is expected to be of type `FixedExprSpanId(<some-length>)`
    pub fn fixed_span_of(self: Self, id: anytype) []const ExprId {
        const span_len = length_of_span_id(@TypeOf(id));
        const start_idx = id.idx;
        const end_idx_exclusive = id.idx + span_len;

        const slice = self.extras.items[start_idx..end_idx_exclusive];
        return bytes_to_expr_ids(slice);
    }

    fn length_of_span_id(comptime IdType: type) comptime_int {
        const error_msg = "Parameter `id` has type `" ++ @typeName(IdType) ++ "`, but `FixedExprSpanId(length)` was expected.";
        if (!@hasDecl(IdType, "span_len")) {
            @compileError(error_msg);
        }
        if (@TypeOf(IdType.span_len) != comptime_int) {
            @compileError(error_msg);
        }
        if (FixedExprSpanId(IdType.span_len) != IdType) {
            @compileError(error_msg);
        }
        return IdType.span_len;
    }

    // pub const FunctionBody = struct {
    //     span: ?TokenSpan,
    //     locals: ?TokenSpan,
    //     expressions: []ExprId,
    // };

    /// Layout of storing `FunctionBody`:
    /// - span: `?TokenSpan`
    ///   - Stored in the first and the second 32 bits.
    ///   - If `span.start_id == 0` and `span.end_id == 0`, then span is considered `null`.
    ///     - This is an okay implementation, since the first token in the AST is always the name of the class
    ///       and not a body of some function.
    ///
    /// - locals: `?TokenSpan`
    ///   - Stored in the third and the fourth 32 bits.
    ///   - If `locals.start_id == 0` and `locals.end_id == 0`, then span is considered `null` (same as `span`)
    ///
    /// - expressions: `[]ExprId`
    ///   - Stored right after `span` and `locals` the same way `variable_span_of` uses to store `[]ExprId`
    ///
    pub fn add_function_body(self: *Self, allocator: Allocator, body: FunctionBody) Allocator.Error!FunctionBodyId {
        const result_function_body_id = FunctionBodyId{ .idx = @truncate(self.extras.items.len) };

        const span: TokenSpan = body.span orelse placeholder_span;
        const locals: TokenSpan = body.locals orelse placeholder_span;

        try self.extras.append(allocator, span.start_id.idx);
        try self.extras.append(allocator, span.end_id.idx);

        try self.extras.append(allocator, locals.start_id.idx);
        try self.extras.append(allocator, locals.end_id.idx);

        const expected_expr_span_idx = self.extras.items.len;
        const expr_span_id = try self.add_variable_span(allocator, body.expressions);
        assert(expr_span_id.idx == expected_expr_span_idx);

        return result_function_body_id;
    }

    /// See `add_function_body` for more info how the storage layout is implemented.
    pub fn function_body_of(self: *Self, id: FunctionBodyId) FunctionBody {
        const span: ?TokenSpan = blk: {
            const span_idx = id.idx;
            const raw_span = TokenSpan.create(
                self.extras.items[span_idx],
                self.extras.items[span_idx + 1],
            );
            break :blk if (std.meta.eql(raw_span, placeholder_span)) null else raw_span;
        };

        const locals: ?TokenSpan = blk: {
            const locals_idx = id.idx + 2;
            const raw_span = TokenSpan.create(
                self.extras.items[locals_idx],
                self.extras.items[locals_idx + 1],
            );
            break :blk if (std.meta.eql(raw_span, placeholder_span)) null else raw_span;
        };

        const expressions_id = ExprSpanId{ .idx = id.idx + 4 };
        const expressions: []const ExprId = self.variable_span_of(expressions_id);

        return FunctionBody{ .span = span, .locals = locals, .expressions = expressions };
    }

    const placeholder_span = TokenSpan.at(TokenId.create(0));
};

pub const ExprSpanId = struct { idx: u32 };

fn FixedExprSpanId(comptime span_lenght: comptime_int) type {
    return struct {
        idx: u32,
        const span_len = span_lenght;
    };
}

pub const SpannedExpr = struct {
    expr: Expression,
    span: TokenSpan,
};

// TODO:
//  - Add doc comments for each field (WITH SYNTAX EXAMPLE)
pub const Expression = union(enum) {
    /// The exact text of the identifier of this variable
    /// can be extracted from the span of this expression.
    ///
    /// TODO(speed): it could actually be stored here as `TokenId`.
    /// That way, we wouldn't have to look up span and it could stay out of the cache.
    /// Since variable access is really common, this could speed up compilation.
    variable,

    integer_literal: IntegerRepresentation,
    float_literal: FloatRepresentation,
    string_literal: TokenId,
    array_literal: ArrayLiteral,

    /// The exact text of the identifier of this variable
    /// can be extracted from the span of this expression.
    ///
    /// TODO(speed): it could actually be stored here as a `TokenSpan`.
    /// That way, we wouldn't have to look up span and it could stay out of the cache.
    symbol,

    exit_expression: struct { return_value: ExprId },
    assignment: struct { variable: TokenId, target_value: ExprId },

    block_literal: BlockLiteral,

    unary_message_call: struct { argument: ExprId, message: TokenId },
    binary_message_call: RawBinaryMessageCall,
    keyword_message_call: KeywordMessageCall,

    const Self = @This();

    pub fn tag(self: Self) std.meta.Tag(Self) {
        return std.meta.activeTag(self);
    }
};

pub const KeywordMessageCall = struct {
    const Self = @This();
    first_argument: ExprId,
    args_id: ExprSpanId,

    /// Keywords are parsed together with `:` at the end
    pub fn nth_keyword(self: Self, n: u32, extras: Extras) TokenId {
        const args = self.get_args(extras);
        return args.nth_keyword(n);
    }

    pub fn nth_argument(self: Self, n: u32, extras: Extras) ExprId {
        const args = self.get_args(extras);
        return args.nth_argument(n);
    }

    pub fn number_of_args(self: Self, extras: Extras) u32 {
        const args = self.get_args(extras);
        return args.number_of_args();
    }

    pub fn get_args(self: Self, extras: Extras) KeywordMessageArgs {
        const span: []const ExprId = extras.variable_span_of(self.args_id);
        return KeywordMessageArgs.create(span);
    }
};

pub const KeywordMessageArgs = struct {
    const Self = @This();
    exprs_span: []const ExprId,

    pub fn create(span: []const ExprId) Self {
        assert(span.len > 0);
        assert(span.len % 2 == 0);
        return .{ .exprs_span = span };
    }

    pub fn number_of_args(self: Self) usize {
        return self.exprs_span.len / 2;
    }

    pub fn nth_keyword(self: Self, n: u32) TokenId {
        assert(n < self.number_of_args());
        // We have to cast the `ExprId` into a `TokenId` here
        // since it is stored that way.
        return TokenId{ .idx = self.exprs_span[n * 2].idx };
    }

    pub fn nth_argument(self: Self, n: u32) ExprId {
        assert(n < self.number_of_args());
        return self.exprs_span[n * 2 + 1];
    }
};

pub const RawBinaryMessageCall = struct {
    const Self = @This();
    info_id: FixedExprSpanId(3),

    pub fn decompress(self: Self, extras: Extras) BinaryMessageCall {
        const slice: []const ExprId = extras.fixed_span_of(self.info_id);
        const lhs: ExprId = slice[0];
        const rhs: ExprId = slice[1];
        const operator: TokenId = TokenId.create(slice[2].idx);
        return BinaryMessageCall{ .lhs = lhs, .rhs = rhs, .message = operator };
    }
};
pub const BinaryMessageCall = struct {
    const Self = @This();

    lhs: ExprId,
    rhs: ExprId,
    message: TokenId,

    pub fn compress_allocating(
        self: Self,
        allocator: Allocator,
        extras: *Extras,
    ) Allocator.Error!RawBinaryMessageCall {
        const info: [3]ExprId = [3]ExprId{
            self.lhs,
            self.rhs,
            ExprId{ .idx = self.message.idx },
        };
        const info_id: FixedExprSpanId(3) = try extras.add_fixed_span(allocator, 3, info);
        return RawBinaryMessageCall{ .info_id = info_id };
    }
};

pub const ArrayLiteral = struct {
    elements: ExprSpanId,
};

pub const BlockParameterIterator = struct {
    const Self = @This();
    next_token_id: TokenId,
    tokens: []Token,

    pub fn next(self: *Self) ?*Token {
        if (self.next_token_id.idx >= self.tokens.len) {
            return null;
        }
        const token: *Token = &self.tokens[self.next_token_id.idx];
        if (token.tag() != .block_param) {
            return null;
        }
        self.next_token_id.idx += 1;
        return token;
    }
};

pub const BlockLiteral = struct {
    const Self = @This();

    /// First token of the parameters for the block.
    /// Used for inner implementation, use `parameters_start` method.
    ///
    /// If `impl_of_paremeters_start.idx == 0` then the block literal has no parameters.
    /// This is an okay implementation, since the first token can never be a block parameter
    ///   for multiple reasons (for example the first token must be the name of the class).
    ///
    impl_of_paremeters_start: TokenId,
    body_id: FunctionBodyId,

    pub fn create(first_parameter_token: ?TokenId, body_id: FunctionBodyId) BlockLiteral {
        return BlockLiteral{
            .impl_of_paremeters_start = first_parameter_token orelse TokenId.create(0),
            .body_id = body_id,
        };
    }

    pub fn parameters_start(self: Self) ?TokenId {
        if (self.impl_of_paremeters_start.idx == 0) return null;
        return self.impl_of_paremeters_start;
    }

    pub fn iter_parameters(self: Self, tokens: []Token) BlockParameterIterator {
        return BlockParameterIterator{
            .tokens = tokens,
            .next_token_id = self.impl_of_paremeters_start,
        };
    }

    pub fn get_parameters(self: Self, tokens: []Token) ?TokenSpan {
        var iter = self.iter_parameters(tokens);
        const start_token = self.impl_of_paremeters_start;
        _ = iter.next() orelse return null;

        var last_token = start_token;
        while (iter.next()) |_| {
            last_token = last_token.plus(1);
        }

        return TokenSpan.create(start_token.idx, last_token.idx);
    }
};

comptime {
    // The maximum available space for a union field is the space for two 32 bit integers.
    const max_payload_size_bytes = (2 * 32) / 8;

    const expression_fields = @typeInfo(Expression).@"union".fields;
    for (expression_fields) |field| {
        const field_size = @sizeOf(field.type);
        if (field_size > max_payload_size_bytes) {
            const err = std.fmt.comptimePrint(
                "The field `{s}` in `{s}` has size {d} bytes, which is more than the maximum {d} bytes.",
                .{ field.name, @typeName(Expression), field_size, max_payload_size_bytes },
            );
            @compileError(err);
        }
    }
}
