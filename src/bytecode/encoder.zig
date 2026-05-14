const std = @import("std");
const Allocator = std.mem.Allocator;

const bytecode_module = @import("__bytecode.zig");
const Bytecode = bytecode_module.Bytecode;
const InstructionId = bytecode_module.InstructionId;
const Instruction = bytecode_module.Instruction;

pub const InstructionEncoder = struct {
    const Self = @This();
    bytes: std.ArrayList(u8),

    pub fn get_final_bytecode(self: *Self, allocator: Allocator) Allocator.Error!Bytecode {
        const bytecode_bytes = try self.bytes.toOwnedSlice(allocator);
        return Bytecode{ .bytes = bytecode_bytes };
    }

    pub fn id_of_the_next_instruction(self: Self) InstructionId {
        const idx = self.bytes.items.len;
        return InstructionId{ .idx = @truncate(idx) };
    }

    pub fn pop_last_instruction(self: *Self, instruction_size_in_bytes: u8) void {
        self.bytes.items.len -= instruction_size_in_bytes;
    }

    pub fn add_instruction(self: *Self, allocator: Allocator, instruction: Instruction) Allocator.Error!InstructionId {
        const instruction_id = self.id_of_the_next_instruction();
        try self.bytes.append(allocator, @intFromEnum(instruction.tag()));

        switch (instruction) {
            inline else => |payload| try self.encode_value(allocator, @TypeOf(payload), payload),
        }

        return instruction_id;
    }

    fn encode_value(self: *Self, allocator: Allocator, comptime Value: type, to_encode: Value) Allocator.Error!void {
        _ = std.builtin.Type;
        switch (@typeInfo(Value)) {
            .void => return,
            .int => try self.write_integer(allocator, to_encode),
            .float => try self.write_float(allocator, to_encode),
            .@"struct" => |struct_info| {
                const BackingInteger: type = struct_info.backing_integer orelse @compileError(std.fmt.comptimePrint(
                    "Cannot encode the struct `{s}`, because it is not a packed struct.\nThe thought behind that we can just dump the struct into the memory, which is faster.",
                    .{@typeName(Value)},
                ));
                const value_raw = @as(BackingInteger, @bitCast(to_encode));
                try self.write_integer(allocator, value_raw);
            },
            else => @compileError(std.fmt.comptimePrint(
                "Cannot encode the type `{s}` (which is `{t}`). Available types to encode are `void`, an integer, a float or a struct.",
                .{ @typeName(Value), @typeInfo(Value) },
            )),
        }
    }

    fn write_float(self: *Self, allocator: Allocator, float: anytype) Allocator.Error!void {
        const raw = bit_cast_float_to_int(float);
        return self.write_integer(allocator, raw);
    }

    fn write_integer(self: *Self, allocator: Allocator, int: anytype) Allocator.Error!void {
        const IntegerType = @TypeOf(int);
        const byte_count = @typeInfo(IntegerType).int.bits / 8;

        var bytes: [byte_count]u8 = undefined;
        std.mem.writeInt(IntegerType, &bytes, int, .little);

        try self.bytes.appendSlice(allocator, &bytes);
    }
};

pub fn IntWithTheSameBitsCountAsFloat(comptime Float: type) type {
    const bits_count = @typeInfo(Float).float.bits;
    return std.meta.Int(.unsigned, bits_count);
}

pub fn bit_cast_float_to_int(float: anytype) IntWithTheSameBitsCountAsFloat(@TypeOf(float)) {
    return @bitCast(float);
}
