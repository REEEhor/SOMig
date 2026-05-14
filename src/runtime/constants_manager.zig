const std = @import("std");
const Allocator = std.mem.Allocator;

const runtime_module = @import("__runtime.zig");
const FunctionBody = runtime_module.FunctionBody;
const types = runtime_module.types;
const VmObject = runtime_module.VmObject;
const BlockDefinition = runtime_module.BlockDefinition;

pub const ConstantsManager = struct {
    strings: std.ArrayHashMapUnmanaged(*types.String, void, StringObjectContext, true),
    blocks: std.ArrayList(*const BlockDefinition),
    allocator: Allocator,

    pub fn init(allocator: Allocator) ConstantsManager {
        return ConstantsManager{
            .allocator = allocator,
            .strings = .empty,
            .blocks = .empty,
        };
    }

    pub fn add_block_definition(self: *Self, block_definition: BlockDefinition) (Allocator.Error || error{too_many_blocks})!BlockDefinitionId {
        if (self.blocks.items.len + 1 > std.math.maxInt(BlockDefinitionId.IdxRepr)) {
            @branchHint(.cold);
            return error.too_many_blocks;
        }
        const block_definition_ptr: *BlockDefinition = try self.allocator.create(BlockDefinition);
        block_definition_ptr.* = block_definition;
        try self.blocks.append(self.allocator, block_definition_ptr);
        return BlockDefinitionId{ .idx = @intCast(self.blocks.items.len - 1) };
    }

    pub fn add_string(self: *Self, string_to_copy: []const u8) (Allocator.Error || error{too_many_string_literals})!StringLiteralId {
        if (self.strings.count() + 1 > std.math.maxInt(StringLiteralId.IdxRepr)) {
            @branchHint(.cold);
            return error.too_many_string_literals;
        }
        const object: VmObject = try types.String.create_new(self.allocator, string_to_copy);
        const string_object: *types.String = object.as_heap_object(.string).?;
        const insert_result = try self.strings.getOrPut(self.allocator, string_object);

        return StringLiteralId{ .idx = @intCast(insert_result.index) };
    }

    pub fn get_string(self: *Self, string_literal_id: StringLiteralId) *types.String {
        return self.strings.keys()[string_literal_id.idx];
    }

    pub fn get_block(self: *Self, block_id: BlockDefinitionId) *const BlockDefinition {
        return self.blocks.items[block_id.idx];
    }

    const StringObjectContext = struct {
        pub fn hash(_: @This(), str: *types.String) u32 {
            return (std.array_hash_map.StringContext{}).hash(str.contents());
        }
        pub fn eql(_: @This(), lhs: *types.String, rhs: *types.String, b_index: usize) bool {
            return (std.array_hash_map.StringContext{}).eql(lhs.contents(), rhs.contents(), b_index);
        }
    };

    const Self = @This();
};

pub const StringLiteralId = packed struct(u32) {
    pub const IdxRepr = u32;
    idx: IdxRepr,
};

pub const BlockDefinitionId = packed struct(u32) {
    pub const IdxRepr = u32;
    idx: IdxRepr,
};
