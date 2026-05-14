const std = @import("std");
const assert = std.debug.assert;

const bytecode_module = @import("__bytecode.zig");
const Bytecode = bytecode_module.Bytecode;
const Instruction = bytecode_module.Instruction;
const InstructionId = bytecode_module.InstructionId;
const IntWithTheSameBitsCountAsFloat = bytecode_module.encoder.IntWithTheSameBitsCountAsFloat;

pub const InstructionDecoder = struct {
    const Self = @This();

    bytes: []const u8,
    next_idx: usize,

    pub const empty = Self{ .bytes = &[_]u8{}, .next_idx = 0 };

    pub fn new(bytecode: Bytecode) Self {
        return InstructionDecoder{
            .bytes = bytecode.bytes,
            .next_idx = 0,
        };
    }

    pub fn is_at_end(self: Self) bool {
        return !(self.next_idx < self.bytes.len);
    }

    pub fn set_id_of_the_next_instruction(self: *Self, id: InstructionId) void {
        self.next_idx = id.idx;
    }

    pub fn id_of_next_instruction(self: Self) InstructionId {
        return InstructionId{ .idx = self.next_idx };
    }

    pub fn fetch_instruction(self: *Self) ?Fetch {
        if (self.is_at_end()) {
            // The code should actually never hit the end.
            // There will always be a `normal_return` or `non_local_return` instruction at the end.
            @branchHint(.cold);
            return null;
        }
        const tag_byte: u8 = self.read_byte();
        const runtime_tag: Instruction.Tag = @enumFromInt(tag_byte);
        return runtime_tag;
    }

    /// return null -> decoder is at the end of the bytecode
    pub inline fn next_instruction(self: *Self) ?Instruction {
        const fetch = self.fetch_instruction() orelse return null;
        switch (fetch) {
            inline else => |access, tag| {
                const payload = access.get(self);
                const instruction = @unionInit(Instruction, @tagName(tag), payload);
                return instruction;
            },
        }
        unreachable;
    }

    pub fn decode_type(self: *Self, comptime ToDecode: type) ToDecode {
        return switch (@typeInfo(ToDecode)) {
            .void => return,
            .int => self.read_integer(ToDecode),
            .float => self.read_float(ToDecode),
            .@"struct" => |struct_info| blk: {
                const BackingInteger: type = struct_info.backing_integer orelse @compileError(std.fmt.comptimePrint(
                    "Cannot decode the struct `{s}`, because it is not a packed struct.",
                    .{@typeName(ToDecode)},
                ));
                const result_raw = self.read_integer(BackingInteger);
                break :blk @as(ToDecode, @bitCast(result_raw));
            },
            else => @compileError(std.fmt.comptimePrint(
                "Cannot decode the type `{s}` (which is `{t}`). Expected either a `void`, an integer or a struct.",
                .{ @typeName(ToDecode), @typeInfo(ToDecode) },
            )),
        };
    }

    pub inline fn read_byte(self: *Self) u8 {
        assert(self.next_idx < self.bytes.len);
        self.next_idx += 1;
        return self.bytes[self.next_idx - 1];
    }

    pub inline fn read_float(self: *Self, comptime FloatType: type) FloatType {
        const bits = self.read_integer(IntWithTheSameBitsCountAsFloat(FloatType));
        return @bitCast(bits);
    }

    pub inline fn read_integer(self: *Self, comptime IntegerType: type) IntegerType {
        const byte_size = @divExact(@typeInfo(IntegerType).int.bits, 8);
        assert(self.next_idx + byte_size <= self.bytes.len); // NOTE the `<=` here!

        const bytes = self.bytes[self.next_idx .. self.next_idx + byte_size];
        const result = std.mem.readVarInt(IntegerType, bytes, .little);

        self.next_idx += byte_size;
        return result;
    }

    pub fn Accessor(comptime instruction_tag: Instruction.Tag) type {
        const Payload: type = @FieldType(Instruction, @tagName(instruction_tag));
        return struct {
            pub fn get(_: @This(), decoder: *InstructionDecoder) Payload {
                return switch (@typeInfo(Payload)) {
                    .void => return,
                    .int => decoder.read_integer(Payload),
                    .float => decoder.read_float(Payload),
                    .@"struct" => |struct_info| blk: {
                        const BackingInteger: type = struct_info.backing_integer orelse @compileError(std.fmt.comptimePrint(
                            "Cannot decode the struct `{s}`, because it is not a packed struct.",
                            .{@typeName(Payload)},
                        ));
                        const result_raw = decoder.read_integer(BackingInteger);
                        break :blk @as(Payload, @bitCast(result_raw));
                    },
                    else => @compileError(std.fmt.comptimePrint(
                        "Cannot decode the type `{s}` (which is `{t}`). Expected either a `void`, an integer or a struct.",
                        .{ @typeName(Payload), @typeInfo(Payload) },
                    )),
                };
            }
        };
    }

    pub const Fetch = blk: {
        @setEvalBranchQuota(1_000_000); // The lookups in the `std.meta.stringToEnum()` take up a lot of jumps
        const instruction_info = @typeInfo(Instruction).@"union";
        const Type = std.builtin.Type;
        var fields: [instruction_info.fields.len]Type.UnionField = undefined;
        for (instruction_info.fields, &fields) |original_field, *new_field| {
            const tag_name = original_field.name;
            const tag_value = std.meta.stringToEnum(Instruction.Tag, tag_name).?;
            new_field.* = Type.UnionField{
                .name = tag_name,
                .type = Accessor(tag_value),
                .alignment = @alignOf(void),
            };
        }
        break :blk @Type(.{ .@"union" = .{
            .tag_type = Instruction.Tag,
            .decls = &.{},
            .layout = .auto,
            .fields = &fields,
        } });
    };
};
