const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const frontend_module = @import("../frontend/__frontend.zig");
const ErrorReporter = frontend_module.ErrorReporter;
const ParsedFile = frontend_module.ParsedFile;
const Ast = frontend_module.ast;
const token_iterator = frontend_module.token_iterator;
const literals = frontend_module.literals;

const bytecode_module = @import("../bytecode/__bytecode.zig");
const Bytecode = bytecode_module.Bytecode;
const Instruction = bytecode_module.Instruction;
const InstructionId = bytecode_module.InstructionId;
const InstructionEncoder = bytecode_module.InstructionEncoder;

const codegen_module = @import("__codegen.zig");
const LexicalScopeStack = codegen_module.LexicalScopeStack;

const interning_module = @import("../interning/__interning.zig");
const SymbolId = interning_module.SymbolId;
const SymbolsManager = interning_module.SymbolsManager;

const runtime_module = @import("../runtime/__runtime.zig");
const ConstantsManager = runtime_module.ConstantsManager;
const MethodDefinition = runtime_module.MethodDefinition;
const ClassDefinition = runtime_module.ClassDefinition;
const SmallPtr = runtime_module.SmallPtr;
const StringLiteralId = runtime_module.StringLiteralId;
const BlockDefinitionId = runtime_module.BlockDefinitionId;
const BlockDefinition = runtime_module.BlockDefinition;
const FunctionBody = runtime_module.FunctionBody;

pub const CompileError = error{
    keyword_selector_too_long,
    too_many_items_in_array_literal,
    super_call_in_class_without_parent,
    could_not_find_method_in_parent,
    too_many_arguments_in_a_block,
    invalid_string_literal,
    invalid_integer_literal,
    too_many_string_literals,
    too_many_blocks,
} || Allocator.Error;

pub const BytecodeGenerator = struct {
    const Self = @This();

    allocator: Allocator,
    temporary_allocator: Allocator,

    symbols_manager: *SymbolsManager,
    constants_manager: *ConstantsManager,
    reporter: *ErrorReporter,

    /// WARN: Do not use from outside of this `struct`!
    /// Invalid between calls to `compile_method`.
    builder: InstructionEncoder = undefined,

    /// WARN: Do not use from outside of this `struct`!
    /// Invalid between calls to `compile_method`.
    ast: *const ParsedFile = undefined,

    /// WARN: Do not use from outside of this `struct`!
    /// Invalid between calls to `compile_method`.
    lexical_scope_stack: *LexicalScopeStack = undefined,

    /// WARN: Do not use from outside of this `struct`!
    /// Invalid between calls to `compile_method`.
    compiled_parent_methods: ?*const ClassDefinition.MethodMap = undefined,

    currently_compiling_block: bool = false,

    last_instruction: ?Instruction = null,

    pub fn init(params: struct {
        allocator: Allocator,
        temporary_allocator: Allocator,
        symbols_manager: *SymbolsManager,
        constants_manager: *ConstantsManager,
        reporter: *ErrorReporter,
    }) Self {
        return Self{
            .allocator = params.allocator,
            .temporary_allocator = params.temporary_allocator,
            .symbols_manager = params.symbols_manager,
            .constants_manager = params.constants_manager,
            .reporter = params.reporter,
        };
    }

    pub fn compile_method(
        self: *Self,
        params: struct {
            ast: *const ParsedFile,
            scope_stack: *LexicalScopeStack,
            compiled_parent_methods: ?*const ClassDefinition.MethodMap,
            //
            method_span: Ast.TokenSpan,
            body: Ast.FunctionBody,
            method_header: Ast.MethodHeader,
        },
    ) CompileError!Bytecode {
        const method_span = params.method_span;
        _ = method_span;
        const body = params.body;
        const method_header = params.method_header;

        self.ast = params.ast;
        defer self.ast = undefined;
        //
        self.lexical_scope_stack = params.scope_stack;
        defer self.lexical_scope_stack = undefined;
        //
        self.compiled_parent_methods = params.compiled_parent_methods;
        defer self.compiled_parent_methods = undefined;

        self.builder = InstructionEncoder{ .bytes = .empty };
        defer self.builder = undefined;

        // Setup arguments
        {
            var arguments_scope = try self.lexical_scope_stack.add_scope(.{ .increase_depth = true });
            var arguments_iterator = method_header.iterate_argument_identifiers_excluding_self();
            // We want to register the identifiers with reverse indexes
            var idx: i64 = @as(i64, method_header.number_of_arguments_including_self()) - 2;
            while (arguments_iterator.next()) |argument_identifier_token| : (idx -= 1) {
                const identifier_symbol: SymbolId = try self.symbol_from_token(argument_identifier_token);
                try arguments_scope.register_variable(.{ .identifier = identifier_symbol, .idx = @intCast(idx) });
            }
            try arguments_scope.register_variable(.{
                .identifier = SymbolsManager.comptime_id_of("self"),
                .idx = method_header.number_of_arguments_including_self() - 1,
            });
            try arguments_scope.register_variable(.{
                .identifier = SymbolsManager.comptime_id_of("super"),
                .idx = method_header.number_of_arguments_including_self() - 1,
            });
        }
        defer self.lexical_scope_stack.pop_scope();

        const bytecode: Bytecode = try self.compile_function_body(.{
            .body = body,
            .number_of_arguments_including_self = method_header.number_of_arguments_including_self(),
        });
        return bytecode;
    }

    fn compile_function_body(
        self: *Self,
        params: struct {
            body: Ast.FunctionBody,
            number_of_arguments_including_self: u32,
        },
    ) CompileError!Bytecode {
        const body = params.body;
        const number_of_arguments_including_self = params.number_of_arguments_including_self;

        // Register local variables into the lexical scope
        {
            // Locals live on the same stackframe as arguments => `.increase_depth = false`
            var locals_scope = try self.lexical_scope_stack.add_scope(.{ .increase_depth = false });
            //
            var local_idx: u32 = number_of_arguments_including_self;
            var iter = token_iterator(body.locals);
            while (iter.next()) |identifier_var_token| : (local_idx += 1) {
                const identifier: SymbolId = try self.symbol_from_token(identifier_var_token);
                try locals_scope.register_variable(.{ .identifier = identifier, .idx = local_idx });
            }
        }
        defer self.lexical_scope_stack.pop_scope();

        // Compile the expressions
        for (body.expressions, 0..) |expr_id, idx| {
            // Compile the expression. The generated bytecode leaves the result value on the top of the stack.
            try self.compile_expression(expr_id);

            // Most of the times, we want to get rid of the value from the on top of the stack and pop it.
            // But we also want to keep the value on the top of the stack in a case we are compiling
            // a block, since we need it for the default return (normal return) of that block.
            const just_compiled_last_expression: bool = ((idx + 1) == body.expressions.len);
            const keep_value_on_the_stack: bool = (self.currently_compiling_block and just_compiled_last_expression);
            if (!keep_value_on_the_stack) {
                try self.add_instruction(.pop);
            }
        }

        if (!self.currently_compiling_block) {
            // Load `self` onto the stack
            try self.add_instruction(.{ .load_local = .{
                .local_id = .{ .idx = number_of_arguments_including_self - 1 },
                .required_frame_up_steps = 0,
            } });
        } else if (body.expressions.len == 0) {
            // We are compiling an empty block => put `nil` onto the stack.
            try self.add_instruction(.load_nil);
        } else {
            // In case we are compiling a *non-empty* block, we left the value on the top of the stack already (in the for-loop).
        }
        try self.add_instruction(.normal_return);

        return try self.builder.get_final_bytecode(self.allocator);
    }

    fn symbol_from_token(self: *Self, token_id: Ast.TokenId) Allocator.Error!SymbolId {
        const token_text = self.ast.text_at(token_id);
        const symbol_id: SymbolId = (try self.symbols_manager.id_or_intern(token_text)).id;
        return symbol_id;
    }

    fn add_instruction(self: *Self, instruction: Instruction) !void {
        _ = try self.builder.add_instruction(self.allocator, instruction);
        self.last_instruction = instruction;
    }

    fn compile_message_send(self: *Self, receiver_id: Ast.ExprId, message_selector: SymbolId) CompileError!void {
        const receiver: Ast.Expression = self.ast.get_expr(receiver_id);
        const is_receiver_super = switch (receiver) {
            .variable => |identifier_token| std.mem.eql(u8, self.ast.text_at(identifier_token), "super"),
            else => false,
        };

        if (!is_receiver_super) {
            try self.compile_expression(receiver_id);
            try self.add_instruction(Instruction{
                .send_message = .{ .message_name = message_selector },
            });
            return;
        }

        // We have to compile a call to a method in the super class
        const parent_methods = if (self.compiled_parent_methods) |methods| methods else {
            self.reporter.report_error(.{ .pos = self.ast.pos_of(receiver_id) }, "Referencing `super` inside a class without a parent class.", .{});
            return CompileError.super_call_in_class_without_parent;
        };
        const method_ptr: *const MethodDefinition = parent_methods.get(message_selector) orelse {
            const selector_as_string = self.symbols_manager.symbol_with_id(message_selector);
            self.reporter.report_warning(
                .{ .pos = self.ast.pos_of(receiver_id) },
                "Call to `super` with the message `{s}`, but the parent does not have a corresponding method defined. This will cause a runtime error.",
                .{selector_as_string},
            );
            try self.add_instruction(.{ .invalid_super_send = .{ .selector = message_selector } });
            return;
        };
        const local_self = self.lexical_scope_stack.lookup_variable(SymbolsManager.comptime_id_of("self")).local_or_method_argument;
        try self.add_instruction(Instruction{ .load_local = .{
            .required_frame_up_steps = local_self.scope_depth_difference,
            .local_id = local_self.local_variable_id,
        } });
        try self.add_instruction(Instruction{
            .resolved_method_call = .{ .method_ptr = SmallPtr(*const MethodDefinition).init(method_ptr) },
        });
    }

    fn compile_expression(self: *Self, expr_id: Ast.ExprId) CompileError!void {
        const expr = self.ast.expressions.get(expr_id);
        switch (expr) {
            .integer_literal => |literal_info| {
                const text = self.ast.text_at(literal_info.absolute_value_token);
                const number: i48 = literals.parse_integer_literal(text, .{ .is_negative = literal_info.is_negative }) orelse blk: {
                    self.reporter.report_warning(
                        .{ .pos = self.ast.pos_of(expr_id) },
                        "This integer literal is too big to fit into the VM representation of integers, which is 48 bits. The valid range is from {d} to {d}.",
                        .{ std.math.minInt(i48), std.math.maxInt(i48) },
                    );
                    break :blk if (literal_info.is_negative) std.math.minInt(i48) else std.math.maxInt(i48);
                };

                if (std.math.cast(i8, number)) |number_i8| {
                    try self.add_instruction(.{ .load_integer_i8 = number_i8 });
                } else {
                    try self.add_instruction(.{ .load_integer_i48 = number });
                }
            },
            .float_literal => |literal_info| {
                const text = self.ast.text_at(literal_info.absolute_value_token);
                var number: f64 = literals.parse_float_literal(text);
                if (literal_info.is_negative) number *= -1;
                try self.add_instruction(.{ .load_double = number });
            },
            .string_literal => |token_id| {
                const string: []const u8 = try self.parse_string_literal(self.temporary_allocator, token_id);
                const string_literal_id: StringLiteralId = self.constants_manager.add_string(string) catch |err| {
                    if (err == error.too_many_string_literals) {
                        self.reporter.report_error(.{ .pos = self.ast.pos_of(token_id) }, "Too many string literals in the codebase (>{d}).", .{std.math.maxInt(StringLiteralId.IdxRepr)});
                    }
                    return err;
                };
                try self.add_instruction(.{ .load_string = string_literal_id });
            },
            .unary_message_send => |unary_call| {
                const message_symbol: SymbolId = try self.symbol_from_token(unary_call.message);
                try self.compile_message_send(unary_call.argument, message_symbol);
            },
            .binary_message_send => |raw_binary_call| {
                const binary_call = raw_binary_call.decompress(self.ast.extras);
                const message_symbol: SymbolId = try self.symbol_from_token(binary_call.message);

                // The calling convention mandates that the order of the arguments is
                // pushed onto the stack in the *REVERSE* order in comparison to the
                // order of the arguments in code.
                try self.compile_expression(binary_call.rhs);
                try self.compile_message_send(binary_call.lhs, message_symbol);
            },
            .keyword_message_send => |keyword_message_call| {
                var writer = std.io.Writer.Allocating.init(self.temporary_allocator);
                const arguments = keyword_message_call.get_args(self.ast.extras);
                for (0..arguments.number_of_args()) |idx| {
                    const keyword_text = self.ast.text_at(arguments.nth_keyword(@intCast(idx)));
                    writer.writer.print("{s}", .{keyword_text}) catch return error.OutOfMemory;
                }
                const selector_as_string = writer.written();
                const selector_symbol: SymbolId = (try self.symbols_manager.id_or_intern(selector_as_string)).id;

                // The calling convention mandates that the order of the arguments is
                // pushed onto the stack in the *REVERSE* order in comparison to the
                // order of the arguments in code.
                //
                // So we compile the arguments in the reverse order.
                for (0..arguments.number_of_args()) |reverse_idx| {
                    const argument_idx: u32 = @intCast(arguments.number_of_args() - reverse_idx - 1);
                    const argument_ast: Ast.ExprId = arguments.nth_argument(argument_idx);
                    try self.compile_expression(argument_ast);
                }
                try self.compile_message_send(keyword_message_call.first_argument, selector_symbol);
            },
            .variable => |identifier_token| {
                const identifier_symbol: SymbolId = try self.symbol_from_token(identifier_token);
                const load_instr: Instruction = sw: switch (self.lexical_scope_stack.lookup_variable(identifier_symbol)) {
                    .instance => |info| {
                        break :sw .{ .load_instance_var = .{
                            .instance_var_id = info.instance_variable_id,
                        } };
                    },
                    .local_or_method_argument => |info| {
                        break :sw .{ .load_local = .{
                            .local_id = info.local_variable_id,
                            .required_frame_up_steps = info.scope_depth_difference,
                        } };
                    },
                    .global => break :sw .{ .load_global = identifier_symbol },
                };
                try self.add_instruction(load_instr);
            },
            .assignment => |assignment| {
                try self.compile_expression(assignment.target_value);
                const identifier_symbol: SymbolId = try self.symbol_from_token(assignment.variable);
                const set_instr: Instruction = switch (self.lexical_scope_stack.lookup_variable(identifier_symbol)) {
                    .instance => |info| .{ .set_instance_var = .{
                        .instance_var_id = info.instance_variable_id,
                    } },
                    .local_or_method_argument => |info| .{ .set_local = .{
                        .local_id = info.local_variable_id,
                        .required_frame_up_steps = info.scope_depth_difference,
                    } },
                    .global => .{ .set_global = identifier_symbol },
                };
                try self.add_instruction(set_instr);
            },
            .exit_expression => |exit_expr| {
                try self.compile_expression(exit_expr.return_value);
                if (self.currently_compiling_block) {
                    try self.add_instruction(.non_local_return);
                } else {
                    try self.add_instruction(.normal_return);
                }
            },
            .array_literal => |array_literal| {
                const sub_expressions: []const Ast.ExprId = self.ast.extras.variable_span_of(array_literal.elements);
                for (sub_expressions) |sub_expression| {
                    try self.compile_expression(sub_expression);
                }
                const max_length = std.math.maxInt(Instruction.PopIntoNewArray.IntRepr);
                if (sub_expressions.len > max_length) {
                    self.reporter.report_error(.{ .pos = self.ast.pos_of(sub_expressions[max_length]) }, "This item causes the array literal to be too long. What are you even doing? Having more than {d} items (the limit) in an array literal seems a bit much.", .{max_length});
                    return error.too_many_items_in_array_literal;
                }
                try self.add_instruction(.{ .pop_into_new_array = .{
                    .number_of_items = @truncate(sub_expressions.len),
                } });
            },
            .symbol => |original_tokens_span| {
                // The symbol should consist of at least a `#` symbol and one more token
                assert(original_tokens_span.number_of_tokens() > 1);
                assert(std.mem.eql(u8, "#", self.ast.text_at(original_tokens_span.start_id)));
                //
                const token_span = Ast.TokenSpan.create(original_tokens_span.start_id.idx + 1, original_tokens_span.end_id.idx);
                var symbol_as_string = self.ast.text_at(token_span);
                if (self.ast.kind_of(token_span.start_id) == .string_literal) {
                    assert(token_span.number_of_tokens() == 1);
                    symbol_as_string = try self.parse_string_literal(self.temporary_allocator, token_span.start_id);
                }
                const symbol_id = (try self.symbols_manager.id_or_intern(symbol_as_string)).id;
                try self.add_instruction(.{ .load_symbol = symbol_id });
            },
            .block_literal => |block_info| {
                const block_id: BlockDefinitionId = try self.compile_block_literal(block_info, expr_id);
                try self.add_instruction(.{ .load_block = block_id });
            },
        }
    }

    fn parse_string_literal(self: *Self, allocator: Allocator, token_id: Ast.TokenId) CompileError![]const u8 {
        assert(self.ast.kind_of(token_id) == .string_literal);
        const text = self.ast.text_at(token_id);
        const string: []const u8 = sw: switch (try literals.parse_string_literal(allocator, text)) {
            .ok => |result| break :sw result.parsed_owned_string,
            .invalid_escape_sequence => |info| {
                self.reporter.report_error(
                    .{ .pos = self.ast.pos_of(token_id) },
                    "This string literal contains invalid escape code \"{s}\".",
                    .{info.invalid_sequence},
                );
                return CompileError.invalid_string_literal;
            },
            .invalid_hex_code => |info| {
                self.reporter.report_error(
                    .{ .pos = self.ast.pos_of(token_id) },
                    "This string literal contains invalid escaped hex code \"{s}\".",
                    .{info.invalid_hex_code},
                );
                return CompileError.invalid_string_literal;
            },
        };
        return string;
    }

    fn compile_block_literal(self: *Self, block_literal: Ast.BlockLiteral, block_expr_id: Ast.ExprId) CompileError!BlockDefinitionId {
        const old_are_we_compiling_block_right_now = self.currently_compiling_block;
        defer self.currently_compiling_block = old_are_we_compiling_block_right_now;
        self.currently_compiling_block = true;

        // We have to use a brand new `InstructionEncoder` for the compilation of the block literal.
        const old_builder = self.builder;
        defer self.builder = old_builder;
        self.builder = InstructionEncoder{ .bytes = .empty };

        // Setup arguments (put them into the lexical scope stack)
        const parameters_count_excluding_self = block_literal.calculate_parameters_count(self.ast.tokens.items(.kind));
        const max_block_parameters_count = 2;
        if (parameters_count_excluding_self > max_block_parameters_count) {
            const parameters_span = block_literal.calculate_parameter_span(self.ast.tokens.items(.kind));
            // SAFETY: We can unwrap `.?` the `parameters_span` because the number of parameters is more than 2.
            //         This means, that the `parameters_span` is not empty.
            const parameters_position = self.ast.pos_of(parameters_span.?);
            self.reporter.report_error(.{ .pos = parameters_position }, "This block has {d} parameters, which is too many. Maximum is {d}.", .{ parameters_count_excluding_self, max_block_parameters_count });
            self.reporter.add_note(.no_location, "Consider taking the arguments as a single array argument with {d} elements.", .{parameters_count_excluding_self});
            return CompileError.too_many_arguments_in_a_block;
        }
        // Register block parameter identifiers as arguments in the lexical scope stack
        {
            var arguments_scope = try self.lexical_scope_stack.add_scope(.{ .increase_depth = true });
            var parameter_iterator = block_literal.iter_parameters(self.ast.tokens.items(.kind));
            // We want to register the identifiers with reverse indexes
            var idx: i64 = @as(i64, @intCast(parameters_count_excluding_self)) - 1;
            while (parameter_iterator.next()) |parameter_token| : (idx -= 1) {
                const parameter_symbol: SymbolId = try self.symbol_from_token(parameter_token);
                try arguments_scope.register_variable(.{ .identifier = parameter_symbol, .idx = @intCast(idx) });
            }
        }
        defer self.lexical_scope_stack.pop_scope();

        const body_ast: Ast.FunctionBody = self.ast.extras.function_body_of(block_literal.body_id);
        const bytecode = try self.compile_function_body(.{
            .body = body_ast,
            .number_of_arguments_including_self = @intCast(parameters_count_excluding_self + 1),
        });

        const block_id = self.constants_manager.add_block_definition(BlockDefinition{
            .body = FunctionBody{
                .bytecode = bytecode,
                .number_of_locals = @intCast(body_ast.number_of_locals()),
            },
            .number_of_aditional_args = @intCast(parameters_count_excluding_self),
        }) catch |err| {
            if (err == error.too_many_blocks) {
                self.reporter.report_error(.{ .pos = self.ast.pos_of(block_expr_id) }, "Too many blocks in the codebase (>{d}).", .{std.math.maxInt(BlockDefinitionId.IdxRepr)});
            }
            return err;
        };
        return block_id;
    }
};
