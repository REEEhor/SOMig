const std = @import("std");
const assert = std.debug.assert;

const runtime_module = @import("../__runtime.zig");
const ClassDefinition = runtime_module.ClassDefinition;
const Stack = runtime_module.Stack;
const MethodDefinition = runtime_module.MethodDefinition;
const Heap = runtime_module.Heap;
const Statics = runtime_module.Statics;
const SmallPtr = runtime_module.SmallPtr;
const BlockDefinition = runtime_module.BlockDefinition;

const objects_module = @import("__objects.zig");
const HeapObject = objects_module.HeapObject;
const OpaqueHeader = objects_module.OpaqueHeader;

pub fn allocate_heap_data(
    allocator: anytype,
    header: anytype,
) std.mem.Allocator.Error!*@TypeOf(header) {
    comptime {
        const info = @typeInfo(@TypeOf(header)).@"struct";
        assert(info.layout == .@"packed");
        assert(info.backing_integer.? == u64);
        //
        assert(info.fields[0].type == HeapObject.Tag);
        assert(std.mem.eql(u8, info.fields[0].name, "tag"));
        //
        assert(info.fields[1].type == bool);
        assert(std.mem.eql(u8, info.fields[1].name, "is_marked"));
        assert(std.meta.hasFn(@TypeOf(header), "object_size_in_bytes"));
    }

    const AllocatorType = @TypeOf(allocator);
    const ptr: *@TypeOf(header) = sw: switch (AllocatorType) {
        *Heap => {
            const heap: *Heap = allocator;
            const opaque_header: *OpaqueHeader = try heap.allocate(header.object_size_in_bytes());
            break :sw @ptrCast(opaque_header);
        },
        *Statics, std.mem.Allocator => {
            const std_allocator: std.mem.Allocator = if (AllocatorType == *Statics) allocator.allocator else allocator;
            const alignment = comptime std.mem.Alignment.fromByteUnits(@alignOf(OpaqueHeader));
            const byte_size: usize = header.object_size_in_bytes();
            const bytes_ptr = try std_allocator.alignedAlloc(u8, alignment, byte_size);
            break :sw @ptrCast(bytes_ptr);
        },
        else => |Invalid| @compileError(std.fmt.comptimePrint(
            "Invalid type for an allocator: `{s}`",
            .{@typeName(Invalid)},
        )),
    };
    ptr.* = header;
    return ptr;
}

pub fn pointer_after(object_ptr: anytype, comptime Item: type) *Item {
    const Object = @typeInfo(@TypeOf(object_ptr)).pointer.child;
    const address = @intFromPtr(object_ptr) + @sizeOf(Object);
    return @ptrFromInt(address);
}

pub fn slice_after(object_ptr: anytype, comptime Item: type, length: usize) []align(@alignOf(@TypeOf(object_ptr))) Item {
    const Object = @typeInfo(@TypeOf(object_ptr)).pointer.child;
    const address = @intFromPtr(object_ptr) + @sizeOf(Object);
    const ptr: [*]align(@alignOf(Object)) Item = @ptrFromInt(address);
    return ptr[0..length];
}
