const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const debug_module = @import("../debug/debug.zig");
const dbg = debug_module.dbg;
const dbg_nl = debug_module.dbg_nl;
const dbgx = debug_module.dbgx;

const interning_module = @import("../interning/symbols_manager.zig");
const SymbolsManager = interning_module.SymbolsManager;
const SymbolId = interning_module.SymbolId;

const token_module = @import("token.zig");
const IntegerRepresentation = token_module.IntegerRepresentation;
const FloatRepresentation = token_module.FloatRepresentation;

const parser_module = @import("parser.zig");
const Parser = parser_module.Parser;

const ast = @import("ast.zig");

const reporter_module = @import("reporter.zig");
const ErrorReporter = reporter_module.ErrorReporter;

/// A unique identifier of a constant in the constants pool.
pub const ConstantId = struct {
    idx: u32,

    pub fn to_relative(self: @This(), base_id: ConstantId) RelativeConstantId {
        assert(self.idx >= base_id.idx);
        const diff: @FieldType(RelativeConstantId, "idx") = @truncate(self.idx - base_id.idx);
        return RelativeConstantId{ .idx = diff };
    }
};

///
/// A unique identifier of a constant in the constants pool *for a given class*.
/// Each class has a `base_id` which is a `ConstantId` of the first constant in the constants pool.
///
/// The instructions themselves store `RelativeConstantId` which is just an offset from the `base_id`.
/// This enables the `load_constant` instruction to be smaller, which is nice for performance reasons.
///
pub const RelativeConstantId = struct {
    idx: u16,

    pub fn to_absolute(self: @This(), base_id: ConstantId) ConstantId {
        return ConstantId{ .idx = base_id.idx + @as(u32, self.idx) };
    }
};

pub const Constant = union(enum) {
    integer: IntegerRepresentation,
    float: FloatRepresentation,
    string: []const u8,
};

pub const ConstantsManager = struct {
    const Self = @This();

    constants: std.MultiArrayList(Constant),
    allocator: Allocator,
    current_base_id: ConstantId,

    /// TODO(speed): make a `init_with_capacity` version or call `ensureCapacity` on `self.constants` for initial capacity
    pub fn init(allocator: Allocator) ConstantsManager {
        return ConstantsManager{
            .allocator = allocator,
            .constants = .empty,
            .current_base_id = ConstantId{ .idx = 0 },
        };
    }

    pub fn next_constant_id(self: Self) ConstantId {
        return ConstantId{ .idx = @truncate(self.constants.len) };
    }

    pub fn new_base_id_for_class(self: *Self) ConstantId {
        self.current_base_id = self.next_constant_id();
        return self.current_base_id;
    }

    pub fn add_constant(self: *Self, new_constant: Constant) Allocator.Error!RelativeConstantId {
        const new_constant_id = self.next_constant_id();
        try self.constants.append(self.allocator, new_constant);
        const relative_id = new_constant_id.to_relative(self.current_base_id);

        return relative_id;
    }

    pub fn get_constant(self: *Self, id: ConstantId) Constant {
        assert(id.idx < self.constants.len);
        return self.constants.get(id.idx);
    }

    pub fn deinit(self: *Self) void {
        self.constants.deinit(self.allocator);
    }
};

pub const BytecodeGenerator = struct {
    const Self = @This();

    allocator: Allocator,

    symbols_manager: *SymbolsManager,
    constants_manager: *ConstantsManager,
    builder: *InstructionEncoder,
    reporter: *ErrorReporter,

    parser: *Parser,
    class_definition: *ast.ClassDefinition,

    pub fn compile(self: *Self) !void {
        _ = self.constants_manager.new_base_id_for_class();

        const instance_portion = self.class_definition.instance_portion;
        const run_method: ast.MethodDefinition = for (instance_portion.methods) |method| {
            const method_name: []const u8 = blk: switch (method.header) {
                .unary => |method_header| break :blk self.parser.text_at(method_header.method_name),
                else => continue,
            };
            if (std.mem.eql(u8, method_name, "run")) break method;
        } else return error.no_run_method;

        const method_body: ast.FunctionBody = switch (run_method.body) {
            .impl => |function_body| function_body,
            else => return error.run_method_is_primitive,
        };

        for (method_body.expressions) |expr_id| {
            try self.compile_expression(expr_id);
            try self.add_instruction(.print);
        }
        try self.add_instruction(.halt);
    }

    fn add_instruction(self: *Self, instruction: Instruction) !void {
        _ = try self.builder.add_instruction(self.allocator, instruction);
    }

    fn compile_expression(self: *Self, expr_id: ast.ExprId) !void {
        const spanned_expr = self.parser.expressions.get_with_span(expr_id);
        const expr = spanned_expr.expr;
        switch (expr) {
            .integer_literal => |value| {
                const constant_id = try self.constants_manager.add_constant(Constant{ .integer = value });
                try self.add_instruction(.{ .load_constant = Instruction.LoadConstant{ .id = constant_id } });
            },
            .float_literal => |value| {
                const constant_id = try self.constants_manager.add_constant(Constant{ .float = value });
                try self.add_instruction(.{ .load_constant = Instruction.LoadConstant{ .id = constant_id } });
            },
            .string_literal => |token_id| {
                const string: []const u8 = self.parser.token_payload(token_id, .string_literal).payload.*;
                const constant_id = try self.constants_manager.add_constant(Constant{ .string = string });
                try self.add_instruction(.{ .load_constant = Instruction.LoadConstant{ .id = constant_id } });
            },
            .unary_message_call => |unary_call| {
                try self.compile_expression(unary_call.argument);
                const message_string = self.parser.text_at(unary_call.message);
                const message: SymbolId = (try self.symbols_manager.id_or_intern(message_string)).id;
                try self.add_instruction(Instruction{
                    .send_message = .{ .message_name = message, .aditional_args_count = 0 },
                });
            },
            .binary_message_call => |raw_binary_call| {
                const binary_call = raw_binary_call.decompress(self.parser.extras);

                // NOTE: compile rhs first! (the VM is stack-based -> swap args :D)
                try self.compile_expression(binary_call.rhs);
                try self.compile_expression(binary_call.lhs);
                const message_string = self.parser.text_at(binary_call.message);
                const message: SymbolId = (try self.symbols_manager.id_or_intern(message_string)).id;
                try self.add_instruction(Instruction{
                    .send_message = .{ .message_name = message, .aditional_args_count = 1 },
                });
            },
            else => |todo_expr| {
                const pos = self.parser.pos_of(spanned_expr.span);
                self.reporter.report_error(
                    .{ .pos = pos },
                    "TODO: Compiling of expression type of '{t}' not implemented yet :D",
                    .{todo_expr.tag()},
                );
            },
        }
    }
};

pub const Bytecode = struct {
    bytes: []const u8,
};

pub const InstructionId = struct { idx: usize };

pub const InstructionDecoder = struct {
    const Self = @This();

    bytes: []const u8,
    next_idx: usize,

    pub fn new(bytecode: Bytecode) Self {
        return InstructionDecoder{
            .bytes = bytecode.bytes,
            .next_idx = 0,
        };
    }

    pub fn is_at_end(self: Self) bool {
        return !(self.next_idx < self.bytes.len);
    }

    pub fn id_of_next_instruction(self: Self) InstructionId {
        return InstructionId{ .idx = self.next_idx };
    }

    /// return null -> decoder is at the end of the bytecode
    pub fn next_instruction(self: *Self) ?Instruction {
        if (self.is_at_end()) {
            // Since in the practical VM code,
            // we will use `halt` to end fetching of the next_instruction
            @branchHint(.cold);
            return null;
        }

        const tag_byte: u8 = self.read_byte();
        const tag: Instruction.Tag = @enumFromInt(tag_byte);
        switch (tag) {
            .load_constant => {
                const idx = self.read_integer(@FieldType(RelativeConstantId, "idx"));
                const load_constant = Instruction.LoadConstant{
                    .id = RelativeConstantId{ .idx = idx },
                };
                return Instruction{ .load_constant = load_constant };
            },
            .send_message => {
                const ArgsCount = @FieldType(Instruction.SendMessage, "aditional_args_count");
                const args_cout = self.read_integer(ArgsCount);
                const message_name_id = self.read_integer(@FieldType(SymbolId, "idx"));

                return Instruction{ .send_message = Instruction.SendMessage{
                    .aditional_args_count = args_cout,
                    .message_name = SymbolId.new(message_name_id),
                } };
            },
            .no_op => return .no_op,
            .duplicate => return .duplicate,
            .halt => return .halt,
            .print => return .print,
        }
    }

    pub inline fn read_byte(self: *Self) u8 {
        assert(self.next_idx < self.bytes.len);
        self.next_idx += 1;
        return self.bytes[self.next_idx - 1];
    }

    pub inline fn read_integer(self: *Self, comptime IntegerType: anytype) IntegerType {
        const byte_size = @divExact(@typeInfo(IntegerType).int.bits, 8);
        assert(self.next_idx + byte_size <= self.bytes.len); // NOTE the `<=` here!

        const bytes = self.bytes[self.next_idx .. self.next_idx + byte_size];
        const result = std.mem.readVarInt(IntegerType, bytes, .little);

        self.next_idx += byte_size;
        return result;
    }
};

pub const InstructionEncoder = struct {
    const Self = @This();
    bytes: std.ArrayList(u8),

    pub fn view_bytecode(self: Self) Bytecode {
        return Bytecode{ .bytes = self.bytes.items };
    }

    pub fn add_instruction(self: *Self, allocator: Allocator, instruction: Instruction) Allocator.Error!InstructionId {
        const start_len = self.bytes.items.len;
        try self.bytes.append(allocator, @intFromEnum(instruction.tag()));

        switch (instruction) {
            .load_constant => |info| {
                try self.write_integer(allocator, info.id.idx);
            },
            .send_message => |info| {
                try self.write_integer(allocator, info.aditional_args_count);
                try self.write_integer(allocator, info.message_name.idx);
            },
            .no_op => {},
            .duplicate => {},
            .halt => {},
            .print => {},
        }

        // const bytes_added = self.bytes.items.len - start_len;
        // TODO(consultation): is this nescessary here?
        // Not really I think, if we have a test that handles all instructions at least two times,
        // it doesn't really need to be here.
        // Also there was a problem with the payload being bigger due to p
        // assert(bytes_added == instruction.payload_byte_size() + 1);

        const instruction_id = InstructionId{ .idx = @truncate(start_len) };
        return instruction_id;
    }

    fn write_integer(self: *Self, allocator: Allocator, int: anytype) Allocator.Error!void {
        const IntegerType = @TypeOf(int);
        const byte_count = @sizeOf(IntegerType);

        var bytes: [byte_count]u8 = undefined;
        std.mem.writeInt(IntegerType, &bytes, int, .little);

        try self.bytes.appendSlice(allocator, &bytes);
    }
};

pub const InstructionFormatter = struct {
    symbols_manager: *SymbolsManager,
    constants_manager: *ConstantsManager,
    base_constant_id: ConstantId,

    pub fn fmt(self: @This(), instruction: Instruction) Fmt {
        return Fmt{
            .instruction = instruction,
            //
            .constants_manager = self.constants_manager,
            .symbols_manager = self.symbols_manager,
            .base_constant_id = self.base_constant_id,
        };
    }

    const Fmt = struct {
        const Writer = std.io.Writer;
        symbols_manager: *SymbolsManager,
        constants_manager: *ConstantsManager,
        instruction: Instruction,
        base_constant_id: ConstantId,

        pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
            const tag_name: []const u8 = @tagName(self.instruction.tag());
            try writer.print("{s:<13}", .{tag_name});

            switch (self.instruction) {
                .load_constant => |load_constant| {
                    const relative_id = load_constant.id;
                    const absolute_id = relative_id.to_absolute(self.base_constant_id);
                    try writer.print(" id({d:03}+{d:03}={d:03}) ", .{ self.base_constant_id.idx, relative_id.idx, absolute_id.idx });
                    try self.print_constant(writer, self.constants_manager.get_constant(absolute_id));
                },
                .send_message => |send_message| {
                    const message_name = self.symbols_manager.symbol_with_id(send_message.message_name);
                    try writer.print(" name=\"{s}\" args-count={d}", .{ message_name, send_message.aditional_args_count });
                },
                // NOTE(epic-zig): comptime assert
                inline else => |payload, tag| {
                    if (@TypeOf(payload) != void) {
                        const error_msg = std.fmt.comptimePrint("Missed instruction `{t}` which has non-void payload type `{s}`", tag, @typeName(@TypeOf(payload)));
                        @compileError(error_msg);
                    }
                },
            }

            try writer.print("\n", .{});
        }

        fn print_constant(self: @This(), writer: *Writer, constant: Constant) Writer.Error!void {
            _ = self;
            switch (constant) {
                .integer => |value| {
                    try writer.print("integer({d})", .{value});
                },
                .float => |value| {
                    try writer.print("float({d})", .{value});
                },
                .string => |value| {
                    try writer.print("string({s})", .{value});
                },
            }
        }
    };
};

pub fn print_bytecode(
    symbols_manager: *SymbolsManager,
    constants_manager: *ConstantsManager,
    base_constant_id: ConstantId,
    bytecode: Bytecode,
    writer: *std.io.Writer,
) std.io.Writer.Error!void {
    const f = InstructionFormatter{
        .constants_manager = constants_manager,
        .symbols_manager = symbols_manager,
        .base_constant_id = base_constant_id,
    };
    var decoder = InstructionDecoder.new(bytecode);
    var instruction_idx: InstructionId = decoder.id_of_next_instruction();

    while (decoder.next_instruction()) |instruction| {
        try writer.print("[{d:04}] {f}", .{ instruction_idx.idx, f.fmt(instruction) });
        instruction_idx = decoder.id_of_next_instruction();
    }
}

// NOTE:
// For versioning reasons, the `InstructionTag` is explicitely listed here together with the numbers
const InstructionTag = enum(u8) {
    no_op = 0,
    load_constant = 1,
    send_message = 2,
    duplicate = 3,
    halt = 4,
    print = 0xff,
};

pub const Instruction = union(InstructionTag) {
    const Tag = InstructionTag;

    no_op,
    load_constant: LoadConstant,
    send_message: SendMessage,
    duplicate,
    halt,
    print, // TODO: remove this after development

    pub const SendMessage = struct {
        message_name: SymbolId,

        /// Number of arguments to pop from stack
        /// (excluding the first argument which is the message target object).
        ///
        /// For example, unary message has this field set to 0 and binary to 1.
        aditional_args_count: u8,
    };
    pub const LoadConstant = struct { id: RelativeConstantId };

    const Self = @This();
    pub fn tag(self: Self) Tag {
        return std.meta.activeTag(self);
    }

    pub fn payload_byte_size(self: Self) u8 {
        switch (self) {
            inline else => |payload| {
                return @sizeOf(@TypeOf(payload));
            },
        }
        unreachable;
    }
};

test InstructionEncoder {
    const allocator = std.testing.allocator;
    var encoder = InstructionEncoder{ .bytes = .empty };
    defer encoder.bytes.deinit(allocator);
    var id: InstructionId = undefined;

    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{},
        encoder.view_bytecode().bytes,
    );

    id = try encoder.add_instruction(allocator, .no_op);
    try std.testing.expectEqual(0, id.idx);
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{0},
        encoder.view_bytecode().bytes,
    );

    id = try encoder.add_instruction(allocator, .no_op);
    try std.testing.expectEqual(1, id.idx);
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 0, 0 },
        encoder.view_bytecode().bytes,
    );

    id = try encoder.add_instruction(allocator, .no_op);
    try std.testing.expectEqual(2, id.idx);
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 0, 0, 0 },
        encoder.view_bytecode().bytes,
    );

    id = try encoder.add_instruction(allocator, .halt);
    try std.testing.expectEqual(3, id.idx);
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 0, 0, 0, 4 },
        encoder.view_bytecode().bytes,
    );

    id = try encoder.add_instruction(allocator, .duplicate);
    try std.testing.expectEqual(4, id.idx);
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 0, 0, 0, 4, 3 },
        encoder.view_bytecode().bytes,
    );

    id = try encoder.add_instruction(allocator, Instruction{
        .load_constant = .{ .id = RelativeConstantId{ .idx = 42 } },
    });
    try std.testing.expectEqual(5, id.idx);
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 0, 0, 0, 4, 3, 1, 42, 0 },
        encoder.view_bytecode().bytes,
    );

    id = try encoder.add_instruction(allocator, .no_op);
    try std.testing.expectEqual(8, id.idx);
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 0, 0, 0, 4, 3, 1, 42, 0, 0 },
        encoder.view_bytecode().bytes,
    );

    id = try encoder.add_instruction(allocator, Instruction{ .send_message = .{
        .message_name = SymbolId.new(68),
        .aditional_args_count = 97,
    } });
    try std.testing.expectEqual(9, id.idx);
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 0, 0, 0, 4, 3, 1, 42, 0, 0, 2, 97, 68, 0, 0, 0, 0, 0, 0, 0 },
        encoder.view_bytecode().bytes,
    );
}

test InstructionDecoder {
    const bytes = [_]u8{ 0, 0, 0, 4, 3, 1, 42, 0, 0, 2, 97, 68, 0, 0, 0, 0, 0, 0, 0 };
    const expected_instructions = [_]Instruction{
        .no_op,
        .no_op,
        .no_op,
        .halt,
        .duplicate,
        Instruction{
            .load_constant = .{ .id = RelativeConstantId{ .idx = 42 } },
        },
        .no_op,
        Instruction{ .send_message = .{
            .message_name = SymbolId.new(68),
            .aditional_args_count = 97,
        } },
    };

    const bytecode = Bytecode{ .bytes = &bytes };
    var decoder = InstructionDecoder.new(bytecode);
    var idx: u32 = 0;
    while (decoder.next_instruction()) |instruction| : (idx += 1) {
        const expected_instruction = expected_instructions[idx];
        std.testing.expectEqualDeep(expected_instruction, instruction) catch |err| {
            std.debug.print("Index of instruction is `{d}`\n", .{idx});
            return err;
        };
    }
}
