const std = @import("std");
const assert = std.debug.assert;

const terminal = @import("../terminal.zig");

const bytecode_module = @import("__bytecode.zig");
const Instruction = bytecode_module.Instruction;
const InstructionId = bytecode_module.InstructionId;
const Bytecode = bytecode_module.Bytecode;
const InstructionDecoder = bytecode_module.InstructionDecoder;

const interning_module = @import("../interning/__interning.zig");
const SymbolsManager = interning_module.SymbolsManager;

const runtime_module = @import("../runtime/__runtime.zig");
const ConstantsManager = runtime_module.ConstantsManager;
const MethodDefinition = runtime_module.MethodDefinition;
const BlockDefinition = runtime_module.BlockDefinition;

const frontend_module = @import("../frontend/__frontend.zig");
const print_escaped_string = frontend_module.print_escaped_string;

pub const InstructionFormatter = struct {
    symbols_manager: *SymbolsManager,
    constants_manager: *ConstantsManager,
    use_color: bool,

    pub fn fmt(self: @This(), instruction: Instruction) Fmt {
        return Fmt{
            .instruction = instruction,
            //
            .constants_manager = self.constants_manager,
            .symbols_manager = self.symbols_manager,
            .use_color = self.use_color,
        };
    }

    const Fmt = struct {
        const Writer = std.io.Writer;
        symbols_manager: *SymbolsManager,
        constants_manager: *ConstantsManager,
        instruction: Instruction,
        use_color: bool,

        pub fn format(self: @This(), writer: *Writer) Writer.Error!void {
            const tag_name: []const u8 = @tagName(self.instruction.tag());
            if (self.use_color) try writer.print(terminal.BOLD, .{});
            try writer.print("{s:<13}", .{tag_name});
            if (self.use_color) try writer.print(terminal.RESET, .{});

            switch (self.instruction) {
                .load_integer_i8 => |integer_value| {
                    try writer.print(" {d}", .{integer_value});
                },
                .load_integer_i48 => |integer_value| {
                    try writer.print(" {d}", .{integer_value});
                },
                .load_double => |double_value| {
                    try writer.print(" {d}", .{double_value});
                },
                .load_string => |string_literal_id| {
                    const string_object = self.constants_manager.get_string(string_literal_id);
                    try writer.print("'", .{});
                    try print_escaped_string(writer, string_object.contents());
                    try writer.print("'", .{});
                },
                .load_block => |block_id| {
                    const block_info = self.constants_manager.get_block(block_id);
                    try writer.print(
                        "block id{d} body-arguments-cnt={d} locals-cnt={d}",
                        .{
                            block_id.idx,
                            block_info.number_of_aditional_args,
                            block_info.body.number_of_locals,
                        },
                    );
                },
                .send_message => |send_message| {
                    const message_name = self.symbols_manager.symbol_with_id(send_message.message_name);
                    try writer.print(" selector=\"{s}\"", .{message_name});
                },
                .load_local => |info| {
                    try writer.print(" id({d}) up-frame-steps={d}", .{ info.local_id.idx, info.required_frame_up_steps });
                },
                .set_local => |info| {
                    try writer.print(" id({d}) up-frame-steps={d}", .{ info.local_id.idx, info.required_frame_up_steps });
                },
                .load_instance_var => |info| {
                    try writer.print(" id({d})", .{info.instance_var_id.idx});
                },
                .set_instance_var => |info| {
                    try writer.print(" id({d})", .{info.instance_var_id.idx});
                },
                .pop_into_new_array => |info| {
                    try writer.print(" items-count={d}", .{info.number_of_items});
                },
                .load_global => |global_var_id| {
                    const identifier: []const u8 = self.symbols_manager.symbol_with_id(global_var_id);
                    try writer.print(" symbol=\"{s}\" id({d})", .{ identifier, global_var_id.idx });
                },
                .set_global => |global_var_id| {
                    const identifier: []const u8 = self.symbols_manager.symbol_with_id(global_var_id);
                    try writer.print(" symbol=\"{s}\" id({d})", .{ identifier, global_var_id.idx });
                },
                .load_symbol => |id| {
                    const string: []const u8 = self.symbols_manager.symbol_with_id(id);
                    try writer.print(" symbol=\"{s}\" id({d})", .{ string, id.idx });
                },
                .invalid_super_send => |info| {
                    const string: []const u8 = self.symbols_manager.symbol_with_id(info.selector);
                    try writer.print(" symbol=\"{s}\" id({d})", .{ string, info.selector.idx });
                },
                .resolved_method_call => |info| {
                    const method_ptr: *const MethodDefinition = info.method_ptr.ptr();
                    try writer.print(
                        " method-name=\"{s}\" is_primitive={s} ptr={x}",
                        .{
                            self.symbols_manager.symbol_with_id(method_ptr.selector),
                            if (std.meta.activeTag(method_ptr.body) == .primitive) "YES" else "NO",
                            @as(usize, @intFromPtr(method_ptr)),
                        },
                    );
                },
                // NOTE(epic-zig): comptime assert
                inline else => |payload, tag| {
                    if (@TypeOf(payload) != void) {
                        const error_msg = std.fmt.comptimePrint("Missed instruction `{t}` which has non-void payload type `{s}`", .{ tag, @typeName(@TypeOf(payload)) });
                        @compileError(error_msg); // Actually saved me a couple of times :D
                    }
                },
            }

            try writer.print("\n", .{});
        }
    };
};

pub fn print_bytecode(
    symbols_manager: *SymbolsManager,
    constants_manager: *ConstantsManager,
    bytecode: Bytecode,
    writer: *std.io.Writer,
    options: struct {
        print_recursive: bool = true,
        indent: usize = 0,
        use_color: bool = true,
    },
) std.io.Writer.Error!void {
    const f = InstructionFormatter{
        .constants_manager = constants_manager,
        .symbols_manager = symbols_manager,
        .use_color = options.use_color,
    };
    var decoder = InstructionDecoder.new(bytecode);
    var instruction_idx: InstructionId = decoder.id_of_next_instruction();

    while (decoder.next_instruction()) |instruction| {
        for (0..10 * options.indent) |_| try writer.writeByte(' ');

        try writer.print("[{d:04}] {f}", .{ instruction_idx.idx, f.fmt(instruction) });
        instruction_idx = decoder.id_of_next_instruction();
        if (!options.print_recursive) continue;

        switch (instruction) {
            .load_block => |block_id| {
                const block_info: *const BlockDefinition = constants_manager.get_block(block_id);
                var options_copy = options;
                options_copy.indent += 1;
                try print_bytecode(
                    symbols_manager,
                    constants_manager,
                    block_info.body.bytecode,
                    writer,
                    options_copy,
                );
            },
            else => {},
        }
    }
}
