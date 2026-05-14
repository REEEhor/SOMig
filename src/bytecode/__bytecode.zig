pub const Instruction = @import("instruction.zig").Instruction;

pub const InstructionDecoder = @import("decoder.zig").InstructionDecoder;

pub const encoder = @import("encoder.zig");
pub const InstructionEncoder = encoder.InstructionEncoder;

pub const instruction_formatter = @import("formatter.zig");
pub const InstructionFormatter = instruction_formatter.InstructionFormatter;
pub const print_bytecode = instruction_formatter.print_bytecode;

pub const Bytecode = struct {
    bytes: []const u8,
};

pub const InstructionId = struct { idx: usize };
